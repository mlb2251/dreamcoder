


import signal
import random
import time
import traceback
import sys
import os
import subprocess
import math
import pickle as pickle
from itertools import chain
import heapq


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)
    flushEverything()


class Bunch(object):
    def __init__(self, d):
        self.__dict__.update(d)

    def __setitem__(self, key, item):
        self.__dict__[key] = item

    def __getitem__(self, key):
        return self.__dict__[key]


def hashable(v):
    """Determine whether `v` can be hashed."""
    try:
        hash(v)
    except TypeError:
        return False
    return True


def flatten(x, abort=lambda x: False):
    """Recursively unroll iterables."""
    if abort(x):
        yield x
        return
    try:
        yield from chain(*(flatten(i, abort) for i in x))
    except TypeError:  # not iterable
        yield x


def summaryStatistics(n, times):
    if len(times) == 0:
        eprint(n, "no successful times to report statistics on!")
    else:
        eprint(n, "average: ", int(mean(times) + 0.5),
               "sec.\tmedian:", int(median(times) + 0.5),
               "\tmax:", int(max(times) + 0.5),
               "\tstandard deviation", int(standardDeviation(times) + 0.5))


NEGATIVEINFINITY = float('-inf')
POSITIVEINFINITY = float('inf')

PARALLELMAPDATA = None


def parallelMap(numberOfCPUs, f, *xs, chunksize=None, maxtasksperchild=None):
    global PARALLELMAPDATA

    if numberOfCPUs == 1:
        return map(f, *xs)

    n = len(xs[0])
    for x in xs:
        assert len(x) == n

    assert PARALLELMAPDATA is None
    PARALLELMAPDATA = (f, xs)

    from multiprocessing import Pool

    # Randomize the order in case easier ones come earlier or later
    permutation = list(range(n))
    random.shuffle(permutation)
    inversePermutation = dict(zip(permutation, range(n)))

    # Batch size of jobs as they are sent to processes
    if chunksize is None:
        chunksize = max(1, n // (numberOfCPUs * 2))
    pool = Pool(numberOfCPUs, maxtasksperchild=maxtasksperchild)
    ys = pool.map(parallelMapCallBack, permutation,
                  chunksize=chunksize)
    pool.terminate()

    PARALLELMAPDATA = None
    return [ys[inversePermutation[j]] for j in range(n)]


def parallelMapCallBack(j):
    global PARALLELMAPDATA
    f, xs = PARALLELMAPDATA
    try:
        return f(*[x[j] for x in xs])
    except Exception as e:
        eprint(
            "Exception in worker during lightweight parallel map:\n%s" %
            (traceback.format_exc()))
        raise e


def log(x):
    t = type(x)
    if t == int or t == float:
        if x == 0:
            return NEGATIVEINFINITY
        return math.log(x)
    return x.log()


def exp(x):
    t = type(x)
    if t == int or t == float:
        return math.exp(x)
    return x.exp()


def lse(x, y=None):
    if y is None:
        largest = None
        if len(x) == 0:
            raise Exception('LSE: Empty sequence')
        if len(x) == 1:
            return x[0]
        # If these are just numbers...
        t = type(x[0])
        if t == int or t == float:
            largest = max(*x)
            return largest + math.log(sum(math.exp(z - largest) for z in x))
        #added clause to avoid zero -dim tensor problem
        import torch
        if t == torch.Tensor and x[0].size() == torch.Size([]):
            return torchSoftMax([datum.view(1) for datum in x])
        # Must be torch
        return torchSoftMax(x)
    else:
        if x is NEGATIVEINFINITY:
            return y
        if y is NEGATIVEINFINITY:
            return x
        tx = type(x)
        ty = type(y)
        if (ty == int or ty == float) and (tx == int or tx == float):
            if x > y:
                return x + math.log(1. + math.exp(y - x))
            else:
                return y + math.log(1. + math.exp(x - y))
        return torchSoftMax(x, y)


def torchSoftMax(x, y=None):
    from torch.nn.functional import log_softmax
    import torch
    if y is None:
        if isinstance(x, list):
            x = torch.cat(x)
        return (x - log_softmax(x, dim=0))[0]
    x = torch.cat((x, y))
    # this is so stupid
    return (x - log_softmax(x, dim=0))[0]


def invalid(x):
    return math.isinf(x) or math.isnan(x)


def valid(x): return not invalid(x)


def forkCallBack(x):
    [f, a, k] = x
    try:
        return f(*a, **k)
    except Exception as e:
        eprint(
            "Exception in worker during forking:\n%s" %
            (traceback.format_exc()))
        raise e


def callFork(f, *arguments, **kw):
    """Forks a new process to execute the call. Blocks until the call completes."""
    global FORKPARAMETERS

    from multiprocessing import Pool

    workers = Pool(1)
    ys = workers.map(forkCallBack, [[f, arguments, kw]])
    workers.terminate()
    assert len(ys) == 1
    return ys[0]


PARALLELPROCESSDATA = None


def launchParallelProcess(f, *a, **k):
    global PARALLELPROCESSDATA

    PARALLELPROCESSDATA = [f, a, k]

    from multiprocessing import Process
    p = Process(target=_launchParallelProcess, args=tuple([]))
    p.start()
    PARALLELPROCESSDATA = None
    return p


def _launchParallelProcess():
    global PARALLELPROCESSDATA
    [f, a, k] = PARALLELPROCESSDATA
    try:
        f(*a, **k)
    except Exception as e:
        eprint(
            "Exception in worker during forking:\n%s" %
            (traceback.format_exc()))
        raise e


class CompiledTimeout(Exception):
    pass


def callCompiled(f, *arguments, **keywordArguments):
    pypyArgs = []
    profile = keywordArguments.pop('profile', None)
    if profile:
        pypyArgs = ['-m', 'vmprof', '-o', profile]

    PIDCallBack = keywordArguments.pop("PIDCallBack", None)

    timeout = keywordArguments.pop('compiledTimeout', None)

    p = subprocess.Popen(['pypy3'] + pypyArgs + ['compiledDriver.py'],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    if PIDCallBack is not None:
        PIDCallBack(p.pid)

    request = {
        "function": f,
        "arguments": arguments,
        "keywordArguments": keywordArguments,
    }
    start = time.time()
    pickle.dump(request, p.stdin)
    dt = time.time() - start
    if dt > 1:
        eprint("(Python side of compiled driver: SLOW) Wrote serialized message for {} in time {}".format(
                f.__name__,
                dt))

    if timeout is None:
        success, result = pickle.load(p.stdout)
    else:
        eprint("Running with timeout", timeout)

        def timeoutCallBack(_1, _2): raise CompiledTimeout()
        signal.signal(signal.SIGALRM, timeoutCallBack)
        signal.alarm(int(math.ceil(timeout)))
        try:
            success, result = pickle.load(p.stdout)
            signal.alarm(0)
        except CompiledTimeout:
            # Kill the process
            p.kill()
            raise CompiledTimeout()

    if not success:
        sys.exit(1)

    return result


class timing(object):
    def __init__(self, message):
        self.message = message

    def __enter__(self):
        self.start = time.time()
        return self

    def __exit__(self, type, value, traceback):
        eprint("%s in %.1f seconds" % (self.message,
                                       time.time() - self.start))


def randomPermutation(l):
    import random
    l = list(l)
    random.shuffle(l)
    return l


def batches(data, size=1):
    import random
    # Randomly permute the data
    data = list(data)
    random.shuffle(data)

    start = 0
    while start < len(data):
        yield data[start:size + start]
        start += size


def sampleDistribution(d):
    """
    Expects d to be a list of tuples
    The first element should be the probability
    If the tuples are of length 2 then it returns the second element
    Otherwise it returns the suffix tuple
    """
    import random

    z = float(sum(t[0] for t in d))
    if z == 0.:
        eprint("sampleDistribution: z = 0")
        eprint(d)
    r = random.random()
    u = 0.
    for t in d:
        p = t[0] / z
        if r < u + p:
            if len(t) <= 2:
                return t[1]
            else:
                return t[1:]
        u += p
    assert False


def sampleLogDistribution(d):
    """
    Expects d to be a list of tuples
    The first element should be the log probability
    If the tuples are of length 2 then it returns the second element
    Otherwise it returns the suffix tuple
    """
    import random

    z = lse([t[0] for t in d])
    r = random.random()
    u = 0.
    for t in d:
        p = math.exp(t[0] - z)
        if r < u + p:
            if len(t) <= 2:
                return t[1]
            else:
                return t[1:]
        u += p
    assert False


def testTrainSplit(x, trainingFraction, seed=0):
    if trainingFraction > 1.1:
        # Assume that the training fraction is actually the number of tasks
        # that we want to train on
        trainingFraction = float(trainingFraction) / len(x)
    needToTrain = {
        j for j, d in enumerate(x) if hasattr(
            d, 'mustTrain') and d.mustTrain}
    mightTrain = [j for j in range(len(x)) if j not in needToTrain]

    import random
    random.seed(seed)
    training = list(range(len(mightTrain)))
    random.shuffle(training)
    training = set(
        training[:int(len(x) * trainingFraction) - len(needToTrain)]) | needToTrain

    train = [t for j, t in enumerate(x) if j in training]
    test = [t for j, t in enumerate(x) if j not in training]
    return test, train


def numberOfCPUs():
    import multiprocessing
    return multiprocessing.cpu_count()


def loadPickle(f):
    with open(f, 'rb') as handle:
        d = pickle.load(handle)
    return d


def fst(l):
    for v in l:
        return v


def mean(l):
    n = 0
    t = None
    for x in l:
        if t is None:
            t = x
        else:
            t = t + x
        n += 1

    if n == 0:
        eprint("warning: asked to calculate the mean of an empty list. returning zero.")
        return 0
    return t / float(n)


def variance(l):
    m = mean(l)
    return sum((x - m)**2 for x in l) / len(l)


def standardDeviation(l): return variance(l)**0.5


def median(l):
    if len(l) <= 0:
        return None
    l = sorted(l)
    if len(l) % 2 == 1:
        return l[len(l) // 2]
    return 0.5 * (l[len(l) // 2] + l[len(l) // 2 - 1])


class Stopwatch():
    def __init__(self):
        self._elapsed = 0.
        self.running = False
        self._latestStart = None

    def start(self):
        if self.running:
            eprint(
                "(stopwatch: attempted to start an already running stopwatch. Silently ignoring.)")
            return
        self.running = True
        self._latestStart = time.time()

    def stop(self):
        if not self.running:
            eprint(
                "(stopwatch: attempted to stop a stopwatch that is not running. Silently ignoring.)")
            return
        self.running = False
        self._elapsed += time.time() - self._latestStart
        self._latestStart = None

    @property
    def elapsed(self):
        e = self._elapsed
        if self.running:
            e = e + time.time() - self._latestStart
        return e


def userName():
    import getpass
    return getpass.getuser()


def hostname():
    import socket
    return socket.gethostname()


def getPID():
    return os.getpid()


def CPULoad():
    try:
        import psutil
    except BaseException:
        return "unknown - install psutil"
    return psutil.cpu_percent()


def flushEverything():
    sys.stdout.flush()
    sys.stderr.flush()


class RunWithTimeout(Exception):
    pass


def runWithTimeout(k, timeout):
    if timeout is None: return k()
    def timeoutCallBack(_1,_2):
        raise RunWithTimeout()
    signal.signal(signal.SIGPROF, timeoutCallBack)
    signal.setitimer(signal.ITIMER_PROF, timeout)
    
    try:
        result = k()
        signal.signal(signal.SIGPROF, lambda *_:None)
        signal.setitimer(signal.ITIMER_PROF, 0)
        return result
    except RunWithTimeout: raise RunWithTimeout()
    except:
        signal.signal(signal.SIGPROF, lambda *_:None)
        signal.setitimer(signal.ITIMER_PROF, 0)
        raise


def crossProduct(a, b):
    b = list(b)
    for x in a:
        for y in b:
            yield x, y


class PQ(object):
    """why the fuck does Python not wrap this in a class"""

    def __init__(self):
        self.h = []
        self.index2value = {}
        self.nextIndex = 0

    def push(self, priority, v):
        self.index2value[self.nextIndex] = v
        heapq.heappush(self.h, (-priority, self.nextIndex))
        self.nextIndex += 1

    def popMaximum(self):
        i = heapq.heappop(self.h)[1]
        v = self.index2value[i]
        del self.index2value[i]
        return v

    def __iter__(self):
        for _, v in self.h:
            yield self.index2value[v]

    def __len__(self): return len(self.h)

class UnionFind:
    class Class:
        def __init__(self, x):
            self.members = {x}
            self.leader = None
        def chase(self):
            k = self
            while k.leader is not None:
                k = k.leader
            self.leader = k
            return k
            
    def __init__(self):
        # Map from keys to classes
        self.classes = {}
    def unify(self,x,y):
        k1 = self.classes[x].chase()
        k2 = self.classes[y].chase()
        # k2 will be the new leader
        k1.leader = k2
        k2.members |= k1.members
        k1.members = None
        self.classes[x] = k2
        self.classes[y] = k2
        return k2
    def newClass(self,x):
        if x not in self.classes:
            n = Class(x)
            self.classes[x] = n

    def otherMembers(self,x):
        k = self.classes[x].chase()
        self.classes[x] = k
        return k.members        
        

    


def substringOccurrences(ss, s):
    return sum(s[i:].startswith(ss) for i in range(len(s)))


def normal(s=1., m=0.):
    u = random.random()
    v = random.random()

    n = math.sqrt(-2.0 * log(u)) * math.cos(2.0 * math.pi * v)

    return s * n + m


if __name__ == "__main__":
    def f():
        while True: pass
        return 5/0
    eprint(runWithTimeout(f, 0.01))

from program import *

from arithmeticPrimitives import *

from functools import reduce

#def _concatenate(x): return lambda y: x + y
#let _empty_tower =
def _empty_tower(h): return (h,[])
def _left(d):
    return lambda k: lambda hand: k(hand - d)
def _right(d):
    return lambda k: lambda hand: k(hand + d)
def _loop(n):
    def f(start, stop, body, hand):
        if start >= stop: return hand,[]
        hand, thisIteration = body(start)(hand)
        hand, laterIterations = f(start + 1, stop, body, hand)
        return hand, thisIteration + laterIterations
    def sequence(b,k,h):
        h,bodyBlocks = f(0,n,b,h)
        h,laterBlocks = k(h)
        return h,bodyBlocks+laterBlocks
    return lambda b: lambda k: lambda h: sequence(b,k,h)
def _simpleLoop(n):
    def f(start, body, k):
        if start >= n: return k
        return body(start)(f(start + 1, body, k))
    return lambda b: lambda k: f(0,b,k)
def _embed(body):
    def f(k):
        def g(hand):
            _, bodyActions = body(_empty_tower)(hand)
            hand, laterActions = k(hand)
            return hand, bodyActions + laterActions
        return g
    return f
    
class TowerContinuation(object):
    def __init__(self, x, w, h):
        self.x = x
        self.w = w*2
        self.h = h*2
    def __call__(self, k):
        def f(hand):
            thisAction = [(self.x + hand,self.w,self.h)]
            hand, rest = k(hand)
            return hand, thisAction + rest
        return f

# name, dimensions
blocks = {  # "1x1": (1.,1.),
             # "2x1": (2.,1.),
             # "1x2": (1.,2.),
    "3x1": (3, 1),
    "1x3": (1, 3),
    #          "4x1": (4.,1.),
    #          "1x4": (1.,4.)
}


ttower = baseType("tower")
primitives = [
    Primitive("left", arrow(tint, ttower, ttower), _left),
    Primitive("right", arrow(tint, ttower, ttower), _right),
    Primitive("tower_loopM", arrow(tint, arrow(tint, ttower, ttower), ttower, ttower), _simpleLoop),
    Primitive("tower_embed", arrow(arrow(ttower,ttower), ttower, ttower), _embed),
] + [Primitive(name, arrow(ttower,ttower), TowerContinuation(0, w, h))
     for name, (w, h) in blocks.items()] + \
         [Primitive(str(j), tint, j) for j in range(1,9) ] + \
         [
#             subtraction
         ]


def executeTower(p, timeout=None):
    try:
        return runWithTimeout(lambda : p.evaluate([])(lambda s: (s,[]))(0)[1],
                              timeout=timeout)
    except RunWithTimeout: return None
    except: return None

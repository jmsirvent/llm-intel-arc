<think>
Okay, so I need to write a Python function that returns the nth Fibonacci number using memoization. Hmm, I remember that the Fibonacci sequence is where each number is the sum of the two preceding ones, usually starting with 0 and 1. So, like, fib(0) is 0, fib(1) is 1, fib(2) is 1, fib(3) is 2, and so on.

Memoization is a technique where we store the results of expensive function calls and return the cached result when the same inputs occur again. That should help make this function more efficient, especially for larger values of n.

Let me think about how to implement this. I can use a dictionary to store the computed Fibonacci numbers. The keys will be the indices, and the values will be the corresponding Fibonacci numbers. So, when the function is called with a particular n, it first checks if n is already in the dictionary. If it is, it returns the stored value. If not, it calculates the value, stores it in the dictionary, and then returns it.

Wait, but how do I handle the base cases? For n=0, it should return 0, and for n=1, it should return 1. So, I'll initialize the memoization dictionary with these two values.

Let me outline the steps:

1. Create a memoization dictionary, maybe called memo, initialized with {0: 0, 1: 1}.
2. Define a function, say fib(n), that checks if n is in memo. If it is, return memo[n].
3. If not, recursively compute fib(n-1) + fib(n-2), store this result in memo, and then return it.

But wait, recursion in Python can hit the recursion limit for large n. Hmm, maybe I should consider an iterative approach or increase the recursion limit. But since the user asked for memoization, perhaps recursion is acceptable for the sake of simplicity, but I should be cautious about stack depth.

Alternatively, I could implement memoization using a decorator, like lru_cache, which automatically handles memoization. That might be easier. Let me think about that.

Yes, using functools.lru_cache would be a neat way to handle memoization without manually managing the dictionary. So, I can import lru_cache from functools, decorate the function with it, and then the function will handle the caching automatically.

But wait, if I use a decorator, I need to make sure that the function is properly decorated. Also, the function should be written in a way that it doesn't have any side effects or other dependencies.

Let me sketch the code:

First, import lru_cache.

Then, define the function:

from functools import lru_cache

@lru_cache(maxsize=None)
def fib(n):
    if n == 0:
        return 0
    elif n == 1:
        return 1
    else:
        return fib(n-1) + fib(n-2)

Wait, but if I use the decorator, I don't need to manage the memoization dictionary myself. The decorator takes care of storing the results.

But is this sufficient? Let me test it with some small values.

fib(0) should return 0. Yes.

fib(1) returns 1. Correct.

fib(2) is fib(1) + fib(0) = 1 + 0 = 1. Correct.

fib(3) is fib(2) + fib(1) = 1 + 1 = 2. Correct.

fib(4) is 3, fib(5) is 5, etc. So, it seems to work.

But what about larger n? Let's say n=10. fib(10) is 55. Let me compute it step by step.

fib(10) = fib(9) + fib(8)
fib(9) = fib(8) + fib(7)
fib(8) = fib(7) + fib(6)
fib(7) = fib(6) + fib(5)
fib(6) = fib(5) + fib(4)
fib(5) = fib(4) + fib(3)
fib(4) = fib(3) + fib(2)
fib(3) = fib(2) + fib(1)
fib(2) = fib(1) + fib(0)
fib(1) = 1
fib(0) = 0

So, working backwards, each step adds up correctly. So, the recursive approach with memoization via lru_cache should work.

But wait, what about the maximum recursion depth? For very large n, say n=1000, the recursive approach might hit the recursion limit in Python. So, for such cases, an iterative approach with memoization would be better.

Hmm, but the user specifically asked for memoization, so perhaps the recursive approach is acceptable, but I should note that for very large n, it might not be efficient.

Alternatively, I can implement an iterative approach with memoization manually.

Let me think about that.

In the iterative approach, I can precompute the Fibonacci numbers up to n and store them in a list or a dictionary. Starting from 0 and 1, each subsequent number is the sum of the previous two.

So, the function would look something like this:

def fib(n):
    memo = {0: 0, 1: 1}
    if n in memo:
        return memo[n]
    for i in range(2, n+1):
        memo[i] = memo[i-1] + memo[i-2]
    return memo[n]

Wait, but this approach doesn't use memoization in the same way as the recursive approach. It's more of a dynamic programming approach where we build up the solution iteratively.

But the user asked for memoization, so perhaps the recursive approach is more aligned with that.

But in the recursive approach, each call to fib(n) will compute fib(n-1) and fib(n-2), which are also computed recursively. So, with memoization, each fib(k) is computed only once.

So, the recursive approach with memoization is more efficient in terms of time and space compared to the iterative approach, especially for larger n.

But again, the issue is that for very large n, recursion depth can be a problem.

Wait, but in Python, the default recursion depth is around 1000. So, for n beyond that, the recursive approach would cause a stack overflow.

So, perhaps the better approach is to use memoization with an iterative method or to increase the recursion limit.

But the user didn't specify any constraints on n, so perhaps it's better to stick with the recursive approach with memoization, knowing that it's efficient for moderate n but may fail for very large n.

Alternatively, I can implement memoization manually without using the decorator, which allows me to handle larger n by increasing the recursion limit.

But that's more complicated.

Alternatively, I can use a decorator that allows for higher recursion limits, but that's not standard.

Alternatively, I can implement the memoization manually with a dictionary and an iterative approach.

Wait, but the user asked for memoization, so perhaps the recursive approach is acceptable.

So, putting it all together, the function would be:

from functools import lru_cache

@lru_cache(maxsize=None)
def fib(n):
    if n == 0:
        return 0
    elif n == 1:
        return 1
    else:
        return fib(n-1) + fib(n-2)

But wait, what if someone calls fib(2)? It would compute fib(1) and fib(0), which are already in the cache. So, it's efficient.

But let me test this function with some examples.

Test case 1: n=0. Should return 0. Correct.

Test case 2: n=1. Should return 1. Correct.

Test case 3: n=2. Should return 1. Correct.

Test case 4: n=3. Should return 2. Correct.

Test case 5: n=10. Should return 55. Let's see:

fib(10) = fib(9) + fib(8)
fib(9) = fib(8) + fib(7)
fib(8) = fib(7) + fib(6)
fib(7) = fib(6) + fib(5)
fib(6) = fib(5) + fib(4)
fib(5) = fib(4) + fib(3)
fib(4) = fib(3) + fib(2)
fib(3) = fib(2) + fib(1)
fib(2) = fib(1) + fib(0)
fib(1) = 1
fib(0) = 0

So, fib(2) = 1
fib(3) = 1 + 1 = 2
fib(4) = 2 + 1 = 3
fib(5) = 3 + 2 = 5
fib(6) = 5 + 3 = 8
fib(7) = 8 + 5 = 13
fib(8) = 13 + 8 = 21
fib(9) = 21 + 13 = 34
fib(10) = 34 + 21 = 55

Yes, correct.

So, the function works for these test cases.

But what about n=5? It should return 5.

fib(5) = fib(4) + fib(3) = 3 + 2 = 5. Correct.

So, the function seems to be working.

But wait, what about negative n? The function as written doesn't handle that. So, perhaps we should add a condition to handle that.

But the problem statement didn't specify, so maybe it's beyond the scope. But perhaps the function should return None or raise an error for negative n.

So, perhaps adding:

if n < 0:
    raise ValueError("n must be a non-negative integer")

But the user didn't specify, so maybe it's not necessary.

Alternatively, the function could handle it, but the problem didn't specify, so perhaps it's not required.

So, the function as written should be correct.

But wait, in the code, I have:

from functools import lru_cache

@lru_cache(maxsize=None)
def fib(n):
    if n == 0:
        return 0
    elif n == 1:
        return 1
    else:
        return fib(n-1) + fib(n-2)

But wait, what if someone calls fib(2)? It will compute fib(1) and fib(0), which are already in the cache. So, it's efficient.

But what about when n is very large, say n=1000? The recursive approach will cause a stack overflow because Python's recursion depth is limited.

So, for n=1000, the function will crash with a maximum recursion depth exceeded error.

So, perhaps the function is not suitable for very large n.

But the user didn't specify any constraints on n, so perhaps it's acceptable.

Alternatively, to handle larger n, we can switch to an iterative approach.

But the user asked for memoization, so perhaps the recursive approach is acceptable.

Alternatively, I can implement memoization manually without using the decorator.

So, let's try that.

Implementing memoization manually:

def fib(n, memo={}):
    if n in memo:
        return memo[n]
    if n == 0:
        memo[n] = 0
    elif n == 1:
        memo[n] = 1
    else:
        memo[n] = fib(n-1, memo) + fib(n-2, memo)
    return memo[n]

Wait, but this is a recursive approach with a mutable default argument, which can cause issues because the same dictionary is used across function calls. That's a problem because if the function is called multiple times, the memo will accumulate results from previous calls, which is not desired.

So, perhaps using a mutable default argument is not a good idea here.

Alternatively, I can pass the memo as an argument, but that complicates the function signature.

Alternatively, I can use a closure or a class-based memoization, but that's more complex.

Alternatively, I can use a decorator that's not lru_cache, but that's not necessary.

Wait, perhaps the initial approach with the decorator is the simplest and most efficient, but it's limited by Python's recursion depth.

So, perhaps the best approach is to use the decorator, but note that for very large n, it may not work.

But the user didn't specify any constraints, so perhaps it's acceptable.

So, the final function is as written above.

But wait, in the initial code, I have:

from functools import lru_cache

@lru_cache(maxsize=None)
def fib(n):
    if n == 0:
        return 0
    elif n == 1:
        return 1
    else:
        return fib(n-1) + fib(n-2)

Yes, that should work.

But let me test it with n=5.

fib(5) should return 5.

Yes, as computed earlier.

So, the function works.

But wait, what about n=2?

fib(2) = fib(1) + fib(0) = 1 + 0 = 1. Correct.

So, the function seems to be correct.

Therefore, the Python function using memoization is as above.
</think>

To solve this problem, we need to write a Python function that returns the nth Fibonacci number using memoization. The Fibonacci sequence is a series of numbers where each number is the sum of the two preceding ones, starting from 0 and 1. Memoization is a technique used to store the results of expensive function calls and return the cached result when the same inputs occur again, which improves efficiency.

### Approach
The approach involves using recursion combined with memoization to efficiently compute the Fibonacci numbers. The key idea is to store each computed Fibonacci number in a dictionary (memo) so that subsequent calls with the same argument can be answered in constant time, O(1), instead of recalculating them.

1. **Memoization with Decorator**: We use Python's `functools.lru_cache` decorator to automatically handle the memoization. This decorator caches the results of the function calls, significantly reducing the number of computations needed for large values of n.
2.

```python
def fibonacci(n, memo={}):
    # Check if the value is already computed and stored in the memo dictionary
    if n in memo:
        return memo[n]
    
    # Base cases for the first two Fibonacci numbers
    if n == 0:
        return 0
    elif n == 1:
        return 1
    
    # Recursive calculation of Fibonacci number with memoization
    result = fibonacci(n-1, memo) + fibonacci(n-2, memo)
    
    # Store the computed result in the memo dictionary to avoid redundant calculations
    memo[n] = result
    
    return result

# Example usage
n = 10
print(fibonacci(n))  # Output: 55
```

In this solution, we define a function `fibonacci` that calculates the nth Fibonacci number using a technique called memoization. Memoization is an optimization technique used primarily to speed up computer programs by storing the results of expensive function calls and returning the cached result when the same inputs occur again. This avoids the need to recompute values that have already been calculated.

The function takes two parameters: `n`, which is the position in the Fibonacci sequence, and `memo`, which is a dictionary used to store previously computed Fibonacci numbers. If the value at position `n` is already in the `memo` dictionary, it returns that value immediately. Otherwise, it computes the Fibonacci number recursively by summing the two preceding numbers (i.e., `fibonacci(n-1)` and `fibonacci(n-2)`), stores the result in the `memo` dictionary, and then returns the result.

This approach significantly improves the efficiency of calculating large Fibonacci numbers compared to a naive recursive implementation without memoization.

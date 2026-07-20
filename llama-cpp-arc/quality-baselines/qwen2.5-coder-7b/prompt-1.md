```python
def fibonacci(n, memo={}):
    # Base cases for the first two Fibonacci numbers
    if n == 0:
        return 0
    elif n == 1:
        return 1
    # Check if the result is already computed and stored in memo dictionary
    if n not in memo:
        # Recursive call to compute the nth Fibonacci number
        memo[n] = fibonacci(n-1, memo) + fibonacci(n-2, memo)
    # Return the nth Fibonacci number from the memo dictionary
    return memo[n]
```

In this solution, the `fibonacci` function calculates the nth Fibonacci number using a technique called memoization. Memoization is a method of storing the results of expensive function calls and returning the cached result when the same inputs occur again. This significantly improves the efficiency of the function, especially for large values of `n`, by avoiding redundant calculations. The function uses a dictionary named `memo` to store the results of previously computed Fibonacci numbers. If the function is called with a value of `n` that has already been computed, it retrieves the result from the `memo` dictionary instead of recalculating it. This approach ensures that each Fibonacci number is computed only once, leading to a time complexity of O(n).

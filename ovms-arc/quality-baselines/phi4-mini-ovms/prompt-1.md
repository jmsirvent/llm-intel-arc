Here's a Python function that returns the nth Fibonacci number using memoization:

```python
def fibonacci(n, memo={}):
    # Check if the value is already computed
    if n in memo:
        return memo[n]
    
    # Base cases
    if n <= 0:
        return 0
    elif n == 1:
        return 1
    
    # Recursive case with memoization
    memo[n] = fibonacci(n - 1, memo) + fibonacci(n - 2, memo)
    
    return memo[n]

# Example usage:
n = 10
print(f"The {n}th Fibonacci number is: {fibonacci(n)}")
```

This function uses a dictionary called `memo` to store previously computed Fibonacci numbers, which helps to avoid redundant calculations and improves performance. The base cases handle the first two Fibonacci numbers, and the recursive case computes the nth Fibonacci number by summing the two preceding numbers.

Here's a Python function to calculate the nth Fibonacci number using memoization:

```python
def fibonacci(n, memo={}):
    # Base cases for the first two Fibonacci numbers
    if n == 0:
        return 0
    elif n == 1:
        return 1
    
    # Check if the result is already in the memo dictionary
    if n in memo:
        return memo[n]
    
    # Recursive calculation with memoization
    memo[n] = fibonacci(n-1, memo) + fibonacci(n-2, memo)
    return memo[n]

# Example usage:
n = 10
print(f"The {n}th Fibonacci number is: {fibonacci(n)}")
```

### Explanation:

- **Base Cases**: The function checks if `n` is 0 or 1, returning 0 and 1 respectively, as these are the first two numbers in the Fibonacci sequence.
- **Memoization**: A dictionary `memo` is used to store previously computed Fibonacci numbers. This avoids redundant calculations and significantly improves efficiency, especially for larger values of `n`.
- **Recursive Calculation**: If the Fibonacci number for `n` is not already in `memo`, the function calculates it recursively by summing the two preceding Fibonacci numbers (`fibonacci(n-1, memo)` and `fibonacci(n-2, memo)`), stores the result in `memo`, and then returns it.

This approach ensures that each Fibonacci number is computed only once, making the function efficient even for large values of `n`.

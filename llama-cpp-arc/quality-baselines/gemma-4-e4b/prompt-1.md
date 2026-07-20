```python
def fibonacci_memo(n, memo={}):
    """
    Calculates the nth Fibonacci number using memoization.

    Args:
        n (int): The index of the Fibonacci number to calculate (n >= 0).
        memo (dict): A dictionary used for memoization (stores already computed results).

    Returns:
        int: The nth Fibonacci number.

    Raises:
        ValueError: If n is a negative number.
    """
    if n < 0:
        raise ValueError("Input must be a non-negative integer.")

    # 1. Check the memoization table (Cache Hit)
    if n in memo:
        return memo[n]

    # 2. Base Cases
    if n == 0:
        return 0
    if n == 1:
        return 1

    # 3. Recursive Step (Cache Miss)
    # Calculate the result recursively
    result = fibonacci_memo(n - 1, memo) + fibonacci_memo(n - 2, memo)

    # 4. Store the result in the memoization table before returning
    memo[n] = result
    return result

# --- Examples ---

# Test cases
print(f"Fibonacci(0): {fibonacci_memo(0)}")  # Expected: 0
print(f"Fibonacci(1): {fibonacci_memo(1)}")  # Expected: 1
print(f"Fibonacci(2): {fibonacci_memo(2)}")  # Expected: 1
print(f"Fibonacci(3): {fibonacci_memo(3)}")  # Expected: 2
print(f"Fibonacci(4): {fibonacci_memo(4)}")  # Expected: 3
print(f"Fibonacci(10): {fibonacci_memo(10)}") # Expected: 55

# Test a larger number to demonstrate efficiency
n_large = 50
print(f"\nCalculating Fibonacci({n_large})...")
result_large = fibonacci_memo(n_large)
print(f"Fibonacci({n_large}): {result_large}")

# Test error handling
try:
    fibonacci_memo(-5)
except ValueError as e:
    print(f"\nError caught: {e}")
```

### Explanation of the Code

1.  **Function Signature (`fibonacci_memo(n, memo={})`):**
    *   It takes `n` (the desired index) and an optional dictionary `memo`.
    *   Using a mutable default argument (`memo={}`) allows the dictionary to persist across recursive calls *within the same top-level function execution*, which is crucial for memoization.

2.  **Error Handling:**
    *   It first checks if `n` is negative and raises a `ValueError` if it is, as the standard Fibonacci sequence is defined for non-negative integers.

3.  **Memoization Check (The Core):**
    ```python
    if n in memo:
        return memo[n]
    ```
    *   Before doing *any* calculation, the function checks if the result for `n` is already stored in the `memo` dictionary. If it is, it immediately returns the stored value, avoiding redundant recursive calls (this is the efficiency gain).

4.  **Base Cases:**
    ```python
    if n == 0:
        return 0
    if n == 1:
        return 1
    ```
    *   These are the stopping conditions for the recursion, defining the start of the sequence ($F_0=0, F_1=1$).

5.  **Recursive Step:**
    ```python
    result = fibonacci_memo(n - 1, memo) + fibonacci_memo(n - 2, memo)
    ```
    *   If the result is not in the memo, the function calculates it using the standard Fibonacci definition: $F_n = F_{n-1} + F_{n-2}$. Crucially, it passes the `memo` dictionary down to the sub-calls.

6.  **Storing the Result:**
    ```python
    memo[n] = result
    return result
    ```
    *   After calculating the `result`, it is stored in the `memo` dictionary using `n` as the key. This ensures that if any future call (even from a different branch of the recursion tree) asks for $F_n$, it will hit the cache in Step 3.

### Time and Space Complexity

*   **Time Complexity: $O(n)$**
    *   

The bug in the code is that it tries to divide by zero when `d` is 0. This will cause a `ZeroDivisionError`.

Here is the corrected code:

```python
def divide_list(nums, d):
    if d == 0:
        return "Error: Division by zero is not allowed."
    else:
        return [n / d for n in nums if n % d == 0]

print(divide_list([10, 15, 20, 7], 0))
```

This code will now return an error message when `d` is 0, instead of trying to divide by zero.

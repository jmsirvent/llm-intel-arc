The bug in your code is that you're trying to divide numbers by zero which will raise a ZeroDivisionError.

Here's how you can fix it:

```python
def divide_list(nums, d):
    if d == 0:
        return "Cannot divide by zero"
    else:
        return [n / d for n in nums if n % d == 0]

print(divide_list([10, 15, 20, 7], 0))
```

In this updated version of the function, we first check if `d` is equal to zero. If it is, we return a string saying "Cannot divide by zero". Otherwise, we proceed with the original list comprehension. This way, we avoid the ZeroDivisionError.

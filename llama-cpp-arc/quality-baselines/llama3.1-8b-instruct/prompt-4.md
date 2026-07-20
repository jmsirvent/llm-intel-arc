```python
import json

def get_number_info(n):
    factors = [i for i in range(1, n + 1) if n % i == 0]
    is_prime = len(factors) == 2  # 1 and the number itself
    return {
        "name": f"Number {n}",
        "is_prime": is_prime,
        "factors": factors
    }

number_info = get_number_info(91)
print(json.dumps(number_info))
```

This script will output:
```json
{"name": "Number 91", "is_prime": false, "factors": [1, 7, 13, 91]}
```

This script works by first generating a list of factors for the given number `n`. It then checks if the number is prime by checking if the length of the list of factors is 2 (i.e., 1 and the number itself). Finally, it returns a dictionary with the required keys and values. The `json.dumps()` function is used to convert the dictionary into a JSON string.

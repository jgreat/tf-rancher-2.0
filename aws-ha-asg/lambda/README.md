# RKE Lambda

## Make and Zip function

```plain
mkdir packages
```

```plain
python3 -m venv ./packages
```

```plain
cd packages
. ./bin/activate
```

```plain
pip install paramiko
pip install pyyaml
```

```plain
cd lib/python3.6/site-packages
zip -r9 ../../../../rke.zip .
```

```plain
cd ../../../../
zip -g rke.zip lambda_function.py
```

## Upload

```plain
terraform apply
```
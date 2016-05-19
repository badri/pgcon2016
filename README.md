```
docker run --name pgcon-demo -e POSTGRES_PASSWORD=pgcon -e POSTGRES_USER=pgcon -d postgres
```

```
postgrest postgres://pgcon:pgcon@<docker-container-ip>:5432/pgcon  --anonymous anon
```

Create your data.

```
import db script.
```

Sign up 2 users.

```
r = requests.post('http://localhost:3000/rpc/signup', json={"email": "user1@example.com", "pass":"s3cr3t"})
r = requests.post('http://localhost:3000/rpc/signup', json={"email": "user2@example.com", "pass":"s3cr3t"})
```

Login as 1st user.

```
import json
r = requests.post('http://localhost:3000/rpc/login', json={"email": "user1@example.com", "pass":"s3cr3t"})
```
token = json.loads(r.text)['token']
headers = {'Authorization': 'Bearer ' + token }
data = {'title': 'Publish this at Github'}
r = requests.post('http://localhost:3000/todos', headers=headers, json=data)


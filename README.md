You can access the presentation [here](http://badri.github.io/pgcon2016/).

# Setup

Get Postgres 9.5 Docker image up and running.

```
$ docker pull postgres:9.5
$ docker run --name pgcon-demo -e POSTGRES_PASSWORD=pgcon -e POSTGRES_USER=pgcon -d postgres
```

```
$ postgrest postgres://pgcon:pgcon@<ip-of-the-container>:5432/pgcon \
  --anonymous anon --jwt-secret correcthorsebatterystaple
```

Import the `schema.sql` file. You should get some notices, but that's OK.

```
$ psql -h <ip-of-the-container> -U pgcon

pgcon=# \i schema.sql
```

Test the API using python.

*NOTE:* you will have to install the [requests](http://docs.python-requests.org/en/master/) library to run these examples.

```
$ pip install requests
```

Simple Nginx configuration to have RESTful urls working.

```
   server {
        listen       80;
        server_name  localhost;
        charset utf-8;
        location / {
            rewrite /([a-z_]+)/([0-9]+) /$1?id=eq.$2 break;
            proxy_pass http://localhost:3000;
        }
    }
```

# Premise

Sign up 2 users.

```
import requests
r = requests.post('http://localhost/rpc/signup', json={"email": "user1@example.com", "pass":"s3cr3t"})
r = requests.post('http://localhost/rpc/signup', json={"email": "user2@example.com", "pass":"s3cr3t"})
```

------------------------------------------------------

# Scenario 1

Login as 1st user.

```
import json
r = requests.post('http://localhost/rpc/login', json={"email": "user1@example.com", "pass":"s3cr3t"})
token = json.loads(r.text)['token']
headers = {'Authorization': 'Bearer ' + token }
data = {'title': 'Publish this at Github'}
r = requests.post('http://localhost/todos', headers=headers, json=data)
```

Login as the other user.

```
r = requests.post('http://localhost/rpc/login', json={"email": "user2@example.com", "pass":"s3cr3t"})
token = json.loads(r.text)['token']
headers = {'Authorization': 'Bearer ' + token }
data = {'title': 'Publish this at Github - user 2'}
r = requests.post('http://localhost/todos', headers=headers, json=data)
```

Add a bunch of todos.

```
for x in range(20):
  data = {'title': 'Publish this at Github - user 2. Todo #' + str(x+1)}
  r = requests.post('http://localhost/todos', headers=headers, json=data)
```

Show all user2's todos.

```
r = requests.get('http://localhost/todos', headers=headers)
r.text
len(json.loads(r.text))
```
Some filtering and ordering

```
r = requests.get('http://localhost/todos?title=like.*18*', headers=headers)
r = requests.get('http://localhost/todos?order=created.desc', headers=headers)
```

Pagination and offsets.

```
headers['Range-Unit'] = 'items'
headers['Range'] =  '0-4'
r = requests.post('http://localhost/todos', headers=headers, json=data)
r = requests.get('http://localhost/todos', headers=headers)
headers = {'Authorization': 'Bearer ' + token }
```


Alter table now, and API reflects changes!

```
ALTER TABLE todos
  ADD COLUMN "complete" BOOLEAN NOT NULL DEFAULT FALSE;
```

```
r = requests.get('http://localhost/todos?select=title,complete', headers=headers)
```

------------------------------------------------------

# Scenario 2

Login as user1 again.
*NOTE* that there is no /logout as JWT is a client side thing. You can implement one by invalidating your JWT.


Let's try logging using invalid credentials.

```
r = requests.post('http://localhost/rpc/login', json={"email": "user1@example.com", "pass":"bad"})
```

This time using the right password,

```
r = requests.post('http://localhost/rpc/login', json={"email": "user1@example.com", "pass":"s3cr3t"})
token = json.loads(r.text)['token']
headers = {'Authorization': 'Bearer ' + token }
```

Show user1's todos:

```
r = requests.get('http://localhost/todos', headers=headers)
r.text
len(json.loads(r.text))
```

Let's see how patch works.

```
data = {'title': 'Have fun at Pgcon 2016!'}
r = requests.post('http://localhost/todos', headers=headers, json=data)
```

Patch a todo.

```
data = {'title': 'Have fun at Pgcon 2016!'}
r = requests.post('http://localhost/todos', headers=headers, json=data)
data = {'title': 'Have fun at Pgcon 2017!'}
r = requests.patch('http://localhost/todos/24', headers=headers, json=data)
```
Delete a todo.

```
r = requests.delete('http://localhost/todos/24', headers=headers)
```

# Contact
[@lakshminp](https://twitter.com/lakshminp)


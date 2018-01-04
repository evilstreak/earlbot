Earlbot
=======

IRC bot providing URL previews


Making
-----

- Run ```make```
- Edit earl.conf to your liking
- Run ```./earl.pl```

Tweets
------

- Create an application at https://dev.twitter.com/apps
- Get an application auth token using your consumer credentials:
```
curl -u $key:$secret -d grant_type=client_credentials https://api.twitter.com/oauth2/token
```
- confirm that ```token_type``` is ```bearer```
- set twittertoken in earl.conf to the contents of ```access_token```

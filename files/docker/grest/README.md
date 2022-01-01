Docker compose for Koios is still under development.

# ENVIRONMENT

Before running, for security, change the default password and username for the postgres database.
To do that, you need to create the `.env` file following the `.env.example` format.

This is done to prevent users from running setups with default passwords available publicly on this repo.

Make sure you change the `POSTGRES_PASSWORD` to your own in the `.env` file.

# RUNNING

`cd files/docker/grest`

`docker-compose up -d`

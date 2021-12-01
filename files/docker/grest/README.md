Docker compose for Koios is still under development.

# ENVIRONMENT

Before running, for security, change the default password and username for the postgres database.
These are defined twice, once in `config/secrets/` and once is the `.env` file you have to create.
Secrets are needed for the official db-sync image, and environment values for the `docker-compose.yml`.
This is done to prevent users from running setups with default passwords available publicly on this repo.

First, replace the `YOUR_USER/YOUR_PASSWORD` in `config/secrets/postgres_user` and ``config/secrets/postgres_password` files.

Then, create the `.env` file following the `.env.example`.
Make sure the `POSTGRES_USER` and `POSTGRES_PASSWORD` match the ones you set in the `secrets` directory.

# RUNNING

`cd files/docker/grest`
`docker-compose up -d`

# Unofficial Instructions for recovering your Byron Era funds on the new Incentivized Shelley Testnet


## 1.  Grab and install Haskell
```
curl -sSL https://get.haskellstack.org/ | sh
```

## 2.  Get the wallet 

note:  you must build from source as of today as there are changes that just got into master you need
```
git clone https://github.com/cardano-foundation/cardano-wallet.git
```

## 3.  Go into the wallet directory
```
cd cardano-wallet
```

## 4. Build the wallet
```
stack build --test --no-run-tests
```
If it fails there are a few reasons we have found:
- The cardano build instructions reference a few things that may be missing.  Check those.
- or maybe one of these would help:

#### Libssl:
```
sudo apt install libssl-dev
```

#### Sqlite : 
```
sudo apt-get install sqlite3 libsqlite3-dev 
```

#### gmp: 
```
sudo apt-get install libgmp3-dev 
```

#### systemd dev: 
```
sudo apt install libsystemd-dev
```

get coffee...  It takes awhile

## 5.  When its done, install executables to your path
```
stack install
```

## 6.  Test to make sure cardano-wallet-jormungandr works fine.
Generate your new mnemonics you will need below.  Note that this generates 15 words as opposed to your byron era mnemnomics which were only 12 words.  

```
cardano-wallet-jormungandr mnemonic generate
```

## 7.  Launch the wallet as a service.
you can either open another terminal window or use screen or something.  anyway, wherever you run this next command you won't be able to use anymore for a terminal until you stop the wallet 

change --node-port 3001 to wherever you have your jormungandr rest interface running.  for me it was 5001..  so

change --port 3002 to wherever you want to access the wallet interface at.  If you have other things running avoid those ports.  for most, 3002 should be free

just to future proof these instructions.  genesis should be whatever genesis you are on.

```
cardano-wallet-jormungandr serve --node-port 3001 --port 3002 --genesis-block-hash e03547a7effaf05021b40dd762d5c4cf944b991144f1ad507ef792ae54603197
```
## 8.  Restore your byron wallet:

--->in another window

replace foo, foo, foo with all your mnemnomics from the byron wallet you are restoring

Also, if you put your wallet on a different port than 3002, fix that too

```
curl -X POST -H "Content-Type: application/json" -d '{ "name": "legacy_wallet", "mnemonic_sentence": ["foo","foo","foo","foo","foo","foo","foo","foo","foo","foo","foo","foo"], "passphrase": "areallylongpassword"}' http://localhost:3002/v2/byron-wallets

```
Thats going to spit out some information about a wallet it creates, you should see the value of your wallet - hopefully its not zero.  And you need the wallet ID for the next step

## 9.  Create your shelley wallet:
Remember all those mnemnomics you made above.. put them here instead of all the foo's.

```
curl -X POST -H "Content-Type: application/json" -d '{ "name": "pool_wallet", "mnemonic_sentence": ["foo","foo","foo","foo","foo","foo","foo","foo","foo","foo","foo","foo","foo","foo","foo"], "passphrase": "areallylongpasswordagain"}' http://localhost:3002/v2/wallets
```
Important thing to get is the wallet id from this command

## 10.  Migrate your funds
Now you are ready to migrate your wallet.  replace the ```<old wallet id>``` and ```<new wallet id>``` with the values you got above

```
curl -X POST -H "Content-Type: application/json" -d '{"passphrase": "areallylongpassword"}' http://localhost:3002/v2/byron-wallets/<old wallet id>/migrations/<new wallet id>
```

## 11.  Congratulations.  your funds are now in your new wallet.  
From here we recommend you send them to a new address entirely owned and created by jcli or whatever method you have been using for the testnet process.

This technically may not be required.  But a lot of us did it and we know it works for setting up pools and stuff.

send a small amount first just to make sure you are in control of the transaction and don't send your funds to la la land.

If you want to send to another address use the command below, but replace the address that you want to send it to, the amount, and your ```<new wallet id>```
```
curl -X POST -H "Content-Type: application/json" -d '{"payments": [ { "address": "<address to send to>"", "amount": { "quantity": 83333330000000, "unit": "lovelace" } } ], "passphrase": "areallylongpasswordagain"}' http://localhost:3002/v2/wallets/<new wallet id>/transactions
```



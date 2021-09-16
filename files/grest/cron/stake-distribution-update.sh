#!/bin/bash
psql cexplorer -c "SELECT GREST.UPDATE_STAKE_DISTRIBUTION_CACHE_CHECK" >> stake-distribution-update.log
#!/usr/bin/env nix-shell
#!nix-shell -p python3Packages.requests python3Packages.tabulate -i python3

"""
Jormungandr Lost Blocks Analysis Tool
Counts the number of blocks produced but ultimately lost (not included in the main chain) in the most recent epoch
"""

__version__ = "0.1.1"

import argparse, requests, os, json, sys
from argparse import RawTextHelpFormatter
from requests.exceptions import HTTPError
from operator import itemgetter

api_url_base = None
api_url = None


def get_api(path):
    r = endpoint(f'{api_url}/{path}')
    return r.text

def get_tip():
    return get_api("tip")

def get_block(block_id):
    r = endpoint(f'{api_url}/block/{block_id}')
    hex_block = r.content.hex()
    return hex_block

def parse_block(block):
    return {
      "epoch": int(block[16:24], 16),
      "slot": int(block[24:32], 16),
      "parent": block[104:168],
      "pool": block[168:232],
    }

def endpoint(url):
    try:
        r = requests.get(url)
        r.raise_for_status()
    except HTTPError as http_err:
        print("\nWeb API unavailable.\nError Details:\n")
        print(f"HTTP error occurred: {http_err}")
        exit(1)
    except Exception as err:
        print("\nWeb API unavailable.\nError Details:\n")
        print(f"Other error occurred: {err}")
        exit(1)
    else:
        return(r)


def check_int(value):
    ivalue = int(value)
    if ivalue <= 0:
        raise argparse.ArgumentTypeError("%s is an invalid positive int value" % value)
    return ivalue

def get_tip_block():
    tip = get_tip()
    block = parse_block(get_block(tip))
    print(block)




def lostblock():
    thisblockhex = get_tip()
    opportunities = 0
    wins = 0
    thisblock = parse_block(get_block(thisblockhex))
    r = endpoint(f'{api_url}/leaders/logs')
    y = json.loads(r.content)
    completed = [x for x in y if x['finished_at_time'] != None]
    for result in sorted(completed, key=itemgetter('finished_at_time'), reverse=True):
        epoch, slot=result['scheduled_at_date'].split(".")
        if(int(epoch) < int(thisblock['epoch'])):
            break
        opportunities += 1
        while(int(slot) < int(thisblock['slot'])):
            thisblockhex = thisblock['parent']
            thisblock = parse_block(get_block(thisblock['parent']))

        if(int(thisblock['epoch']) == int(epoch) and int(thisblock['slot']) == int(slot)):
            if(thisblockhex == result['status']['Block']['block']):
                wins += 1
            # else:
            #    print("lost to " + thisblock['pool'])
    print(opportunities - wins)

def main():
    global api_url_base
    global api_url

    if args.restapi is not None:
        api_url_base = args.restapi
    else:
        api_url_base = os.environ.get("JORMUNGANDR_RESTAPI_URL", "http://localhost:5001/api")
    api_url = f"{api_url_base}/v0"

    lostblock()

    exit(0)

if __name__ == "__main__":

    parser = argparse.ArgumentParser(description=(
        "Examines Leader logs for win/lost ratio in multi-leader slots\n\n"),
        formatter_class=RawTextHelpFormatter)

    parser.add_argument("-v", "--version", action="store_true",
                        help="Show the program version and exit")

    parser.add_argument("-r", "--restapi", nargs="?", metavar="RESTAPI", type=str, const="http://127.0.0.1:3001/api",
                        help="Set the rest api to utilize; by default: \"http://127.0.0.1:3001/api\".  An env var of JORMUNGANDR_RESTAPI_URL can also be seperately set. ")

    args = parser.parse_args()

    if args.version:
        print(f'Version: {__version__}\n')
        exit(0)
    main()


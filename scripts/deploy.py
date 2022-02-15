from pathlib import Path

from brownie import accounts, config, network, project, web3, Contract, Strategy0xDAOStaker
from eth_utils import is_checksum_address
import click

def main():
    vault = Contract("0x0fBbf9848D969776a5Eb842EdAfAf29ef4467698")
    pid = 21
    strategy_name = "StrategyHECStakerBoo"
    masterchef = Contract("0x2352b745561e7e6FCD03c093cE7220e3e126ace0")
    emission_token = Contract("0x5C4FDfc5233f935f20D2aDbA572F770c2E377Ab0")
    swap_first_step = Contract("0x8D11eC38a3EB5E956B052f67Da8Bdc9bef8Abf3E")
    auto_sell = True

    strategist = accounts.load('yearn')

    strategy = strategist.deploy(
        Strategy0xDAOStaker,
        vault,
        pid,
        strategy_name,
        masterchef,
        emission_token,
        swap_first_step,
        auto_sell,
    )

    print(strategy)
import brownie
from brownie import Contract
from brownie import config
import math


def test_simple_harvest(
    gov,
    token,
    vault,
    strategist,
    whale,
    strategy,
    chain,
    strategist_ms,
    amount,
    accounts
):
    ## deposit to the vault after approving
    startingWhale = token.balanceOf(whale)
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})
    newWhale = token.balanceOf(whale)

    # harvest, store asset amount
    chain.sleep(1)
    strategy.harvest({"from": gov})
    chain.sleep(1)
    old_assets = vault.totalAssets()
    assert old_assets > 0
    assert token.balanceOf(strategy) == 0
    assert strategy.estimatedTotalAssets() > 0
    print("\nStarting vault total assets: ", old_assets / 1e18)

    # simulate 12 hours of earnings
    chain.sleep(43200)
    chain.mine(1)

    # harvest, store new asset amount
    chain.sleep(1)
    strategy.harvest({"from": gov})
    chain.sleep(1)
    new_assets = vault.totalAssets()
    # confirm we made money, or at least that we have about the same
    assert new_assets >= old_assets
    print("\nVault total assets after 1 harvest: ", new_assets / 1e18)

    # Display estimated APR
    print(
        "\nEstimated APR: ",
        "{:.2%}".format(
            ((new_assets - old_assets) * (365 * 2)) / (strategy.estimatedTotalAssets())
        ),
    )
    
    # transfer 1000 BOO from our other whale to the xBOO contract
    print("Total Estimated Assets before donation:", strategy.estimatedTotalAssets()/1e18)
    whale_2 = accounts.at("0xE0c15e9Fe90d56472D8a43da5D3eF34ae955583C", force=True)
    xboo = Contract("0xa48d959AE2E88f1dAA7D5F611E01908106dE7598")
    token.transfer(xboo.address, 1000e18, {"from": whale_2})
    print("Total Estimated Assets After Donation:", strategy.estimatedTotalAssets()/1e18)

    # simulate 12 hours of earnings
    chain.mine(1)
    chain.sleep(43200)

    # harvest, store new asset amount
    chain.sleep(1)
    tx = strategy.harvest({"from": gov})
    chain.sleep(1)
    new_assets = vault.totalAssets()
    # confirm we made money, or at least that we have about the same
    assert new_assets >= old_assets
    print("\nVault total assets after next harvest: ", new_assets / 1e18)

    # Display estimated APR
    print(
        "\nEstimated APR with fake xBOO yield: ",
        "{:.2%}".format(
            ((new_assets - old_assets) * (365 * 2)) / (strategy.estimatedTotalAssets())
        ),
    )

    # withdraw and confirm we made money, or at least that we have about the same
    vault.withdraw({"from": whale})
    assert token.balanceOf(whale) >= startingWhale

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
    accounts,
    masterchef,
    reward_token,
    pid,
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

    # check on our pending rewards
    pending = masterchef.pendingOXD(pid, strategy, {"from": whale})
    print("This is our pending reward after 12 hours: $" + str(pending / 1e18))

    # harvest, store new asset amount. Turn off health check since we are only ones in this pool.
    chain.sleep(1)
    tx = strategy.harvest({"from": gov})
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

    # withdraw and confirm we made money, or at least that we have about the same
    vault.withdraw({"from": whale})
    assert token.balanceOf(whale) >= startingWhale

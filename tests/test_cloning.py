import brownie
from brownie import Wei, accounts, Contract, config

# test passes as of 21-06-26
def test_cloning(
    gov,
    token,
    vault,
    strategist,
    whale,
    strategy,
    keeper,
    rewards,
    chain,
    Strategy0xDAOStaker,
    guardian,
    amount,
    pid,
    masterchef,
    strategy_name,
    emission_token,
    swap_first_step,
    auto_sell,
):
    # Shouldn't be able to call initialize again
    with brownie.reverts():
        strategy.initialize(
            vault,
            strategist,
            rewards,
            keeper,
            pid,
            strategy_name,
            masterchef,
            emission_token,
            swap_first_step,
            auto_sell,
            {"from": gov},
        )

    ## clone our strategy
    tx = strategy.clone0xDAOStaker(
        vault,
        strategist,
        rewards,
        keeper,
        pid,
        strategy_name,
        masterchef,
        emission_token,
        swap_first_step,
        auto_sell,
        {"from": gov},
    )
    newStrategy = Strategy0xDAOStaker.at(tx.return_value)

    # Shouldn't be able to call initialize again
    with brownie.reverts():
        newStrategy.initialize(
            vault,
            strategist,
            rewards,
            keeper,
            pid,
            strategy_name,
            masterchef,
            emission_token,
            swap_first_step,
            auto_sell,
            {"from": gov},
        )

    ## shouldn't be able to clone a clone
    with brownie.reverts():
        newStrategy.clone0xDAOStaker(
            vault,
            strategist,
            rewards,
            keeper,
            pid,
            strategy_name,
            masterchef,
            emission_token,
            swap_first_step,
            auto_sell,
            {"from": gov},
        )

    # revoke and send all funds back to vault
    vault.revokeStrategy(strategy, {"from": gov})
    strategy.setDoHealthCheck(False, {"from": gov})
    strategy.harvest({"from": gov})

    # attach our new strategy and approve it on the proxy
    vault.addStrategy(newStrategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})

    assert vault.withdrawalQueue(1) == newStrategy
    assert vault.strategies(newStrategy)[2] == 10_000
    assert vault.withdrawalQueue(0) == strategy
    assert vault.strategies(strategy)[2] == 0

    ## deposit to the vault after approving; this is basically just our simple_harvest test
    before_pps = vault.pricePerShare()
    startingWhale = token.balanceOf(whale)
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})

    # harvest, store asset amount
    tx = newStrategy.harvest({"from": gov})
    old_assets_dai = vault.totalAssets()
    assert old_assets_dai > 0
    assert token.balanceOf(newStrategy) == 0
    assert newStrategy.estimatedTotalAssets() > 0
    print("\nStarting Assets: ", old_assets_dai / (10 ** token.decimals()))

    # simulate nine days of earnings to make sure we hit at least one epoch of rewards
    chain.sleep(86400)
    chain.mine(1)

    # harvest after a day, store new asset amount
    newStrategy.setDoHealthCheck(False, {"from": gov})
    newStrategy.harvest({"from": gov})
    new_assets_dai = vault.totalAssets()
    # we can't use strategyEstimated Assets because the profits are sent to the vault
    assert new_assets_dai >= old_assets_dai
    print("\nAssets after 2 days: ", new_assets_dai / (10 ** token.decimals()))

    # Display estimated APR
    print(
        "\nEstimated APR: ",
        "{:.2%}".format(
            ((new_assets_dai - old_assets_dai) * (365))
            / (newStrategy.estimatedTotalAssets())
        ),
    )

    apr = ((new_assets_dai - old_assets_dai) * (365)) / (
        newStrategy.estimatedTotalAssets()
    )
    assert apr > 0

    # simulate a day of waiting for share price to bump back up
    chain.sleep(86400)
    chain.mine(1)

    # withdraw and confirm we made money
    vault.withdraw({"from": whale})
    assert token.balanceOf(whale) >= startingWhale
    assert vault.pricePerShare() > before_pps

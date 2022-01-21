import brownie
from brownie import Contract
from brownie import config
import math


def test_protocol_drains_balance(
    gov,
    token,
    vault,
    strategist,
    whale,
    strategy,
    chain,
    strategist_ms,
    pid,
    amount,
    masterchef,
):
    ## deposit to the vault after approving.
    startingWhale = token.balanceOf(whale)
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})
    chain.sleep(1)
    strategy.setDoHealthCheck(False, {"from": gov})
    strategy.harvest({"from": gov})
    chain.sleep(1)

    # send away all funds from the masterchef itself
    to_send = token.balanceOf(masterchef)
    print("Balance of Vault", to_send)
    token.transfer(gov, to_send, {"from": masterchef})
    assert token.balanceOf(masterchef) == 0
    assert vault.strategies(strategy)[2] == 10000

    # turn off health check since we're doing weird shit
    strategy.setDoHealthCheck(False, {"from": gov})

    # revoke the strategy to get our funds back out
    vault.revokeStrategy(strategy, {"from": gov})
    chain.sleep(1)
    tx_1 = strategy.harvest({"from": gov})
    chain.sleep(1)
    print("\nThis was our vault report:", tx_1.events["Harvested"])

    # we can also withdraw from an empty vault as well
    tx = vault.withdraw(amount, whale, 10000, {"from": whale})
    endingWhale = token.balanceOf(whale)
    print(
        "This is how much our whale lost:",
        (startingWhale - endingWhale) / (10 ** token.decimals()),
    )


def test_protocol_half_rekt(
    gov,
    token,
    vault,
    strategist,
    whale,
    strategy,
    chain,
    strategist_ms,
    pid,
    amount,
    masterchef,
):
    ## deposit to the vault after approving.
    startingWhale = token.balanceOf(whale)
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})
    chain.sleep(1)
    strategy.setDoHealthCheck(False, {"from": gov})
    strategy.harvest({"from": gov})
    chain.sleep(1)

    # send away all funds from the masterchef itself
    to_send = token.balanceOf(masterchef) / 2
    starting_chef = token.balanceOf(masterchef)
    print("Balance of Vault", to_send)
    token.transfer(gov, to_send, {"from": masterchef})
    assert token.balanceOf(masterchef) < starting_chef

    # turn off health check since we're doing weird shit
    strategy.setDoHealthCheck(False, {"from": gov})

    # revoke the strategy to get our funds back out
    vault.revokeStrategy(strategy, {"from": gov})
    chain.sleep(1)
    tx = strategy.harvest({"from": gov})
    chain.sleep(1)
    print("\nThis was our vault report:", tx.events["Harvested"])

    # we can also withdraw from an empty vault as well
    vault.withdraw(amount, whale, 10000, {"from": whale})
    endingWhale = token.balanceOf(whale)
    print(
        "This is how much our whale lost:",
        (startingWhale - endingWhale) / (10 ** token.decimals()),
    )


def test_protocol_dumb_token_dev(
    gov,
    token,
    vault,
    strategist,
    whale,
    strategy,
    chain,
    strategist_ms,
    pid,
    amount,
    masterchef,
    reward_token,
):
    ## deposit to the vault after approving.
    startingWhale = token.balanceOf(whale)
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})
    chain.sleep(1)
    strategy.setDoHealthCheck(False, {"from": gov})
    strategy.harvest({"from": gov})
    chain.sleep(1)

    # normal operation
    chain.sleep(86400)
    chain.mine(1)
    strategy.setDoHealthCheck(False, {"from": gov})
    tx_1 = strategy.harvest({"from": gov})
    chain.sleep(1)
    chain.mine(1)

    # change token owner from masterchef to our whale, what a sneak!
    reward_token.transferOwnership(whale, {"from": masterchef})
    chain.sleep(86400)
    chain.mine(1)

    # check if we can still withdraw normally if this happened, let's set emergency exit
    strategy.setEmergencyExit({"from": gov})
    chain.sleep(1)
    with brownie.reverts():
        strategy.harvest({"from": gov})

    # we have to use emergencyWithdraw here
    strategy.emergencyWithdraw({"from": gov})
    chain.sleep(1)
    tx_2 = strategy.harvest({"from": gov})
    chain.sleep(1)
    print("\nThis was our vault report:", tx_2.events["Harvested"])

    # we may lose a few wei here due to rounding
    tx = vault.withdraw(amount, whale, 10000, {"from": whale})
    endingWhale = token.balanceOf(whale)
    print(
        "This is how much our whale lost:",
        (startingWhale - endingWhale) / (10 ** token.decimals()),
    )


def test_protocol_dumb_masterchef_dev(
    gov,
    token,
    vault,
    strategist,
    whale,
    strategy,
    chain,
    strategist_ms,
    pid,
    amount,
    masterchef,
    reward_token,
):
    ## deposit to the vault after approving.
    startingWhale = token.balanceOf(whale)
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})
    chain.sleep(1)
    strategy.setDoHealthCheck(False, {"from": gov})
    strategy.harvest({"from": gov})
    chain.sleep(1)

    # normal operation
    chain.sleep(86400)
    chain.mine(1)
    strategy.setDoHealthCheck(False, {"from": gov})
    tx_1 = strategy.harvest({"from": gov})
    chain.sleep(1)
    chain.mine(1)

    # try and add a duplicate pool to bork the contract. since our strategist deployed it, he is the owner.
    owner = Contract("0xa96D2F0978E317e7a97aDFf7b5A76F4600916021")
    with brownie.reverts():
        masterchef.add(69, token, {"from": owner})
    with brownie.reverts():
        masterchef.set(pid, 6900, {"from": owner})

    # check that we can still withdraw just fine if owner sets rewards to 0
    masterchef.set(pid, 0, {"from": owner})
    chain.sleep(86400)
    chain.mine(1)

    # check if we can still withdraw normally if this happened, let's revoke
    vault.revokeStrategy(strategy, {"from": gov})
    chain.sleep(1)
    strategy.setDoHealthCheck(False, {"from": gov})
    tx_2 = strategy.harvest({"from": gov})
    chain.sleep(1)
    print("\nThis was our vault report:", tx_2.events["Harvested"])

    # we can also withdraw from an empty vault as well
    vault.withdraw({"from": whale})


def test_withdraw_when_done_rewards_over(
    gov,
    token,
    vault,
    strategist,
    whale,
    strategy,
    chain,
    strategist_ms,
    pid,
    amount,
    masterchef,
    reward_token,
):
    ## deposit to the vault after approving.
    startingWhale = token.balanceOf(whale)
    token.approve(vault, 2 ** 256 - 1, {"from": whale})
    vault.deposit(amount, {"from": whale})
    chain.sleep(1)
    strategy.setDoHealthCheck(False, {"from": gov})
    strategy.harvest({"from": gov})
    chain.sleep(1)

    # turn off health check since we're doing weird shit
    strategy.setDoHealthCheck(False, {"from": gov})

    # normal operation
    chain.sleep(60 * 86400)
    chain.mine(1)
    tx_1 = strategy.harvest({"from": gov})
    chain.sleep(86400)
    chain.mine(1)

    # check if we can still withdraw normally if this happened, let's revoke
    vault.revokeStrategy(strategy, {"from": gov})
    chain.sleep(1)
    tx_2 = strategy.harvest({"from": gov})
    chain.sleep(1)
    print("\nThis was our vault report:", tx_2.events["Harvested"])

    # we can also withdraw from an empty vault as well
    vault.withdraw({"from": whale})

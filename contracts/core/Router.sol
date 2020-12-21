// Copyright (C) 2020 Zerion Inc. <https://zerion.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity 0.7.3;
pragma experimental ABIEncoderV2;

import {
    AbsoluteTokenAmount,
    Action,
    AmountType,
    Fee,
    Input,
    PermitType,
    TokenAmount,
    TransactionData
} from "../shared/Structs.sol";
import { ERC20 } from "../interfaces/ERC20.sol";
import { SafeERC20 } from "../shared/SafeERC20.sol";
import { Helpers } from "../shared/Helpers.sol";
import { ChiToken } from "../interfaces/ChiToken.sol";
import { Core } from "./Core.sol";
import { Logger } from "./Logger.sol";
import { Ownable } from "./Ownable.sol";
import { SignatureVerifier } from "./SignatureVerifier.sol";
import { UniswapRouter } from "./UniswapRouter.sol";

interface Chi {
    function freeFromUpTo(address, uint256) external;
}

contract Router is
    Logger,
    Ownable,
    UniswapRouter,
    SignatureVerifier("Zerion Router v1.1")
{
    using SafeERC20 for ERC20;
    using Helpers for address;

    address internal immutable core_;

    address internal constant CHI = 0x0000000000004946c0e9F43F4Dee607b0eF1fA1c;
    uint256 internal constant DELIMITER = 1e18; // 100%
    uint256 internal constant FEE_LIMIT = 1e16; // 1%
    // Constants of non-value type not yet implemented,
    // so we have to combine all the selectors into one bytes12 constant.
    //    bytes4[3] internal constant PERMIT_SELECTORS = [
    //        // PermitType.DAI
    //        // keccak256(abi.encodePacked('permit(address,address,uint256,uint256,bool,uint8,bytes32,bytes32)'))
    //        0x8fcbaf0c,
    //        // PermitType.EIP2612
    //        // keccak256(abi.encodePacked('permit(address,address,uint256,uint256,uint8,bytes32,bytes32)'))
    //        0xd505accf,
    //        // PermitType.Yearn
    //        // keccak256(abi.encodePacked('permit(address,address,uint256,uint256,bytes[65])'))
    //        0x53ab5ce3
    //    ];
    bytes12 internal constant PERMIT_SELECTORS = 0x8fcbaf0cd505accf53ab5ce3;

    /**
     * @dev The amount used as second parameter of freeFromUpTo() function
     * is the solution of the following equation:
     * 21000 + calldataCost + executionCost + constBurnCost + n * perTokenBurnCost =
     * 2 * (24000 * n + otherRefunds)
     * Here,
     *     calldataCost = 7 * msg.data.length
     *     executionCost = 21000 + gasStart - gasleft()
     *     constBurnCost = 25171
     *     perTokenBurnCost = 6148
     *     otherRefunds = 0
     */
    modifier useCHI {
        uint256 gasStart = gasleft();
        _;
        uint256 gasSpent = 21000 + gasStart - gasleft() + 7 * msg.data.length;
        ChiToken(CHI).freeFromUpTo(msg.sender, (gasSpent + 25171) / 41852);
    }

    constructor(address payable core) {
        require(core != address(0), "R: empty core");

        core_ = core;
    }

    // solhint-disable-next-line no-empty-blocks
    receive() external payable {}

    /**
     * @notice Returns tokens mistakenly sent to this contract.
     * @dev Can be called only by this contract's owner.
     */
    function returnLostTokens(address token, address payable beneficiary) external onlyOwner {
        if (token == ETH) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool success, ) = beneficiary.call{ value: address(this).balance }(new bytes(0));
            require(success, "R: bad beneficiary");
        } else {
            ERC20(token).safeTransfer(beneficiary, ERC20(token).balanceOf(address(this)), "R");
        }
    }

    /**
     * @return Address of the Core contract used.
     */
    function core() external view returns (address) {
        return core_;
    }

    /**
     * @notice Executes actions and returns tokens to account.
     * Uses CHI tokens previously approved by the msg.sender.
     * @param data TransactionData struct with the following elements:
     * @param actions Array of actions to be executed.
     * @param inputs Array of tokens to be taken from the signer of this data.
     * @param fee Fee struct with fee details.
     * @param requiredOutputs Array of requirements for the returned tokens.
     * @param account Address of the account that will receive the returned tokens.
     * @param salt Number that makes this data unique.
     * @param signature EIP712-compatible signature of data.
     * @return Array of AbsoluteTokenAmount structs with the returned tokens.
     * @dev This function uses CHI token to refund some gas.
     */
    function executeWithCHI(
        Action[] memory actions,
        Input[] memory inputs,
        Fee memory fee,
        AbsoluteTokenAmount[] memory requiredOutputs,
        uint256 salt,
        bytes memory signature
    ) public payable useCHI returns (AbsoluteTokenAmount[] memory) {
        bytes32 hashedData = hashData(actions, inputs, fee, requiredOutputs, salt);
        address payable account = getAccountFromSignature(hashedData, signature);

        markHashUsed(hashedData, account);

        return execute(actions, inputs, fee, requiredOutputs, account);
    }

    /**
     * @notice Executes actions and returns tokens to account.
     * Uses CHI tokens previously approved by the msg.sender.
     * @param actions Array of actions to be executed.
     * @param inputs Array of tokens to be taken from the msg.sender.
     * @param fee Fee struct with fee details.
     * @param requiredOutputs Array of requirements for the returned tokens.
     * @return Array of AbsoluteTokenAmount structs with the returned tokens.
     * @dev This function uses CHI token to refund some gas.
     */
    function executeWithCHI(
        Action[] memory actions,
        Input[] memory inputs,
        Fee memory fee,
        AbsoluteTokenAmount[] memory requiredOutputs
    ) public payable useCHI returns (AbsoluteTokenAmount[] memory) {
        return execute(actions, inputs, fee, requiredOutputs);
    }

    /**
     * @notice Executes actions and returns tokens to account.
     * @param data TransactionData struct with the following elements:
     * @param actions Array of actions to be executed.
     * @param inputs Array of tokens to be taken from the signer of this data.
     * @param fee Fee struct with fee details.
     * @param requiredOutputs Array of requirements for the returned tokens.
     * @param account Address of the account that will receive the returned tokens.
     * @param salt Number that makes this data unique.
     * @param signature EIP712-compatible signature of data.
     * @return Array of AbsoluteTokenAmount structs with the returned tokens.
     */
    function executeWithCHI(
        Action[] memory actions,
        Input[] memory inputs,
        Fee memory fee,
        AbsoluteTokenAmount[] memory requiredOutputs,
        address account,
        uint256 salt,
        bytes memory signature
    ) public payable useCHI returns (AbsoluteTokenAmount[] memory) {
        bytes32 hashedData = hashData(actions, inputs, fee, requiredOutputs, salt);
        require(
            data.account == getAccountFromSignature(hashedData, signature),
            "R: wrong account"
        );

        markHashUsed(hashedData, account);

        return
            execute(
                actions,
                inputs,
                fee,
                requiredOutputs,
                payable(account)
            );
    }

    /**
     * @notice Executes actions and returns tokens to account.
     * @param actions Array of actions to be executed.
     * @param inputs Array of tokens to be taken from the msg.sender.
     * @param fee Fee struct with fee details.
     * @param requiredOutputs Array of requirements for the returned tokens.
     * @return Array of AbsoluteTokenAmount structs with the returned tokens.
     */
    function execute(
        Action[] memory actions,
        Input[] memory inputs,
        Fee memory fee,
        AbsoluteTokenAmount[] memory requiredOutputs
    ) public payable returns (AbsoluteTokenAmount[] memory) {
        return execute(actions, inputs, fee, requiredOutputs, msg.sender);
    }

    /**
     * @dev Executes actions and returns tokens to account.
     * @param actions Array of actions to be executed.
     * @param inputs Array of tokens to be taken from the account address.
     * @param fee Fee struct with fee details.
     * @param requiredOutputs Array of requirements for the returned tokens.
     * @param account Address of the account that will receive the returned tokens.
     * @return Array of AbsoluteTokenAmount structs with the returned tokens.
     */
    function execute(
        Action[] memory actions,
        Input[] memory inputs,
        Fee memory fee,
        AbsoluteTokenAmount[] memory requiredOutputs,
        address payable account
    ) internal returns (AbsoluteTokenAmount[] memory) {
        // Transfer tokens to Core contract, handle fees (if any), and add these tokens to outputs
        transferTokens(inputs, fee, account);
        AbsoluteTokenAmount[] memory modifiedOutputs = modifyOutputs(requiredOutputs, inputs);

        // Call Core contract with all provided ETH, actions, expected outputs and account address
        AbsoluteTokenAmount[] memory actualOutputs =
            Core(payable(core_)).executeActions(actions, modifiedOutputs, account);

        // Emit event so one could track account and fees of this tx.
        emit Executed(account, fee.share, fee.beneficiary);

        // Return tokens' addresses and amounts that were returned to the account address
        return actualOutputs;
    }

    /**
     * @dev Transfers tokens from account address to the core_ contract
     * and takes fees if needed.
     * @param inputs Array of tokens to be taken from the account address.
     * @param fee Fee struct with fee details.
     * @param account Address of the account tokens will be transferred from.
     */
    function transferTokens(
        Input[] memory inputs,
        Fee memory fee,
        address account
    ) internal {
        address token;
        uint256 absoluteAmount;
        uint256 feeAmount;
        uint256 length = inputs.length;

        if (fee.share > 0) {
            require(fee.beneficiary != address(0), "R: bad beneficiary");
            require(fee.share <= FEE_LIMIT, "R: bad fee");
        }

        for (uint256 i = 0; i < length; i++) {
            token = inputs[i].tokenAmount.token;
            absoluteAmount = getAbsoluteAmount(inputs[i].tokenAmount, account);
            require(absoluteAmount > 0, "R: zero amount");

            uint256 allowance = ERC20(token).allowance(account, address(this));
            if (absoluteAmount > allowance) {
                (bool success, bytes memory returnData) =
                    // solhint-disable-next-line avoid-low-level-calls
                    token.call(
                        abi.encodePacked(
                            getPermitSelector(inputs[i].permit.permitType),
                            inputs[i].permit.permitCallData
                        )
                    );

                // assembly revert opcode is used here as `returnData`
                // is already bytes array generated by the callee's revert()
                // solhint-disable-next-line no-inline-assembly
                assembly {
                    if eq(success, 0) {
                        revert(add(returnData, 32), returndatasize())
                    }
                }
            }

            feeAmount = mul(absoluteAmount, fee.share) / DELIMITER;

            if (feeAmount > 0) {
                ERC20(token).safeTransferFrom(account, fee.beneficiary, feeAmount, "R[1]");
            }

            ERC20(token).safeTransferFrom(account, core_, absoluteAmount - feeAmount, "R[2]");
            emit TokenTransfer(token, account, absoluteAmount - feeAmount);
        }

        if (msg.value > 0) {
            feeAmount = mul(msg.value, fee.share) / DELIMITER;

            if (feeAmount > 0) {
                // solhint-disable-next-line avoid-low-level-calls
                (bool success, ) = fee.beneficiary.call{ value: feeAmount }(new bytes(0));
                require(success, "ETH transfer to beneficiary failed");
            }

            // solhint-disable-next-line avoid-low-level-calls
            (bool success, ) = core_.call{ value: msg.value - feeAmount }(new bytes(0));
            require(success, "ETH transfer to Core failed");
            emit TokenTransfer(ETH, account, msg.value - feeAmount);
        }
    }

    /**
     * @dev Returns the absolute token amount given the TokenAmount struct.
     * @param tokenAmount TokenAmount struct with token address, amount, and amount type.
     * @param account Address of the account absolute token amount will be calculated for.
     * @return Absolute token amount.
     */
    function getAbsoluteAmount(TokenAmount memory tokenAmount, address account)
        internal
        view
        returns (uint256)
    {
        address token = tokenAmount.token;
        AmountType amountType = tokenAmount.amountType;
        uint256 amount = tokenAmount.amount;

        require(
            amountType == AmountType.Relative || amountType == AmountType.Absolute,
            "R: bad amount type"
        );

        if (amountType == AmountType.Relative) {
            require(amount <= DELIMITER, "R: bad amount");
            if (amount == DELIMITER) {
                return ERC20(token).balanceOf(account);
            } else {
                return mul(ERC20(token).balanceOf(account), amount) / DELIMITER;
            }
        } else {
            return amount;
        }
    }

    /**
     * @dev Appends tokens from inputs to the requiredOutputs list.
     * @return Array of AbsoluteTokenAmount structs with the resulting tokens.
     */
    function modifyOutputs(
        AbsoluteTokenAmount[] memory requiredOutputs,
        Input[] memory inputs
    ) internal view returns (AbsoluteTokenAmount[] memory) {
        uint256 ethInput = msg.value > 0 ? 1 : 0;
        AbsoluteTokenAmount[] memory modifiedOutputs =
            new AbsoluteTokenAmount[](requiredOutputs.length + inputs.length + ethInput);

        for (uint256 i = 0; i < requiredOutputs.length; i++) {
            modifiedOutputs[i] = requiredOutputs[i];
        }

        for (uint256 i = 0; i < inputs.length; i++) {
            modifiedOutputs[requiredOutputs.length + i] = AbsoluteTokenAmount({
                token: inputs[i].tokenAmount.token,
                absoluteAmount: 0
            });
        }

        if (ethInput > 0) {
            modifiedOutputs[requiredOutputs.length + inputs.length] = AbsoluteTokenAmount({
                token: ETH,
                absoluteAmount: 0
            });
        }

        return modifiedOutputs;
    }

    function getPermitSelector(PermitType permitType) internal pure returns (bytes4) {
        require(permitType != PermitType.None, "R: permit is required but not provided");
        uint256 permitIndex = uint256(uint8(permitType) - 1);

        return bytes4(PERMIT_SELECTORS << (permitIndex * 32));
    }

    /**
     * @dev Safe multiplication operation.
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, "R: mul overflow");

        return c;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Finds a CREATE2 salt such that the hook address carries the required permission bits (low 14 bits).
///         Trimmed copy of Uniswap v4-periphery's HookMiner (MIT).
library HookMiner {
    uint160 constant FLAG_MASK = 0x3FFF;
    uint256 constant MAX_LOOP = 300_000;

    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        flags = flags & FLAG_MASK;
        bytes memory creationCodeWithArgs = abi.encodePacked(creationCode, constructorArgs);
        bytes32 initHash = keccak256(creationCodeWithArgs);
        for (uint256 s; s < MAX_LOOP; s++) {
            hookAddress = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, s, initHash)))));
            if (uint160(hookAddress) & FLAG_MASK == flags && hookAddress.code.length == 0) {
                return (hookAddress, bytes32(s));
            }
        }
        revert("HookMiner: could not find salt");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IDCAVault {
    function isScheduleReady(address user, uint256 scheduleId) external view returns (bool);
    function executeSwap(
        address user,
        uint256 scheduleId,
        bytes calldata swapData
    ) external;
}

/**
 * @title DCAResolver
 * @notice Gelato resolver contract for automated DCA execution
 * @dev Determines if a DCA schedule is ready for execution
 */
contract DCAResolver {
    // ============ State ============
    IDCAVault public dcaVault;
    
    // ============ Events ============
    event VaultSet(address indexed vault);
    
    // ============ Constructor ============
    constructor(address _vault) {
        require(_vault != address(0), "Invalid vault");
        dcaVault = IDCAVault(_vault);
        emit VaultSet(_vault);
    }
    
    // ============ Gelato Checker ============
    /**
     * @notice Gelato calls this to determine if task should execute
     * @return canExec Whether the task is ready to execute
     * @return execPayload Encoded call data for execution
     */
    function checker(address user, uint256 scheduleId)
        external
        view
        returns (bool canExec, bytes memory execPayload)
    {
        canExec = dcaVault.isScheduleReady(user, scheduleId);
        
        if (canExec) {
            // Return the data to call executeSwap
            // In production, you'd construct proper swap data from 1inch API
            execPayload = abi.encodeCall(
                dcaVault.executeSwap,
                (user, scheduleId, "")
            );
        }
    }
    
    /**
     * @notice Batch check multiple schedules
     * @return executables Array of schedules ready for execution
     */
    function batchChecker(address user, uint256[] calldata scheduleIds)
        external
        view
        returns (
            uint256[] memory executables,
            bytes[] memory execPayloads
        )
    {
        uint256[] memory ready = new uint256[](scheduleIds.length);
        bytes[] memory payloads = new bytes[](scheduleIds.length);
        uint256 count = 0;
        
        for (uint256 i = 0; i < scheduleIds.length; i++) {
            if (dcaVault.isScheduleReady(user, scheduleIds[i])) {
                ready[count] = scheduleIds[i];
                payloads[count] = abi.encodeCall(
                    dcaVault.executeSwap,
                    (user, scheduleIds[i], "")
                );
                count++;
            }
        }
        
        // Resize arrays to actual count
        executables = new uint256[](count);
        execPayloads = new bytes[](count);
        
        for (uint256 i = 0; i < count; i++) {
            executables[i] = ready[i];
            execPayloads[i] = payloads[i];
        }
    }
}

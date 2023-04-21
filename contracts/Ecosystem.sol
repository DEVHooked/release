// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Context.sol";

contract Ecosystem is Context {
    event ERC20Released(address indexed token, uint256 amount);

    uint256 private _released;
    uint256 private _erc20Released;
    address private immutable _beneficiary;
    address private immutable _token;
    uint64 private immutable _start = 1672531200;
    uint64 private immutable _duration = 1827619200 - 1672531200;

    /**
     * @dev Array with pre-calculated timestamps for each release period
     */
    uint256[60] private _unlockTimestamps = [
        1672531200, 1675209600, 1677628800, 1680307200, 1682899200, 1685577600, 1688169600, 1690848000, 1693526400, 1696118400, 
        1698796800, 1701388800, 1704067200, 1706745600, 1709251200, 1711929600, 1714521600, 1717200000, 1719792000, 1722470400, 
        1725148800, 1727740800, 1730419200, 1733011200, 1735689600, 1738368000, 1740787200, 1743465600, 1746057600, 1748736000, 
        1751328000, 1754006400, 1756684800, 1759276800, 1761955200, 1764547200, 1767225600, 1769904000, 1772323200, 1775001600, 
        1777593600, 1780272000, 1782864000, 1785542400, 1788220800, 1790812800, 1793491200, 1796083200, 1798761600, 1801440000, 
        1803859200, 1806537600, 1809129600, 1811808000, 1814400000, 1817078400, 1819756800, 1822348800, 1825027200, 1827619200];

    constructor(address tokenAddress, address beneficiaryAddress) {
        require(tokenAddress != address(0), "Ecosystem: token is zero address");
        require(beneficiaryAddress != address(0), "Ecosystem: beneficiary is zero address");
        _token = tokenAddress;
        _beneficiary = beneficiaryAddress;
    }

    /**
     * @dev Getter for the beneficiary address.
     */
    function beneficiary() public view virtual returns (address) {
        return _beneficiary;
    }

    /**
     * @dev Getter for the start timestamp.
     */
    function start() public view virtual returns (uint256) {
        return _start;
    }

    /**
     * @dev Getter for the release duration.
     */
    function duration() public view virtual returns (uint256) {
        return _duration;
    }

    /**
     * @dev Amount of token already released
     */
    function released() public view virtual returns (uint256) {
        return _erc20Released;
    }

    /**
     * @dev Amount of token that can be released
     */
    function releasable() public view virtual returns (uint256) {
        return releasedAmount(_token, uint64(block.timestamp)) - released();
    }

    function release() public virtual {
        uint256 amount = releasable();
        _erc20Released += amount;
        emit ERC20Released(_token, amount);
        SafeERC20.safeTransfer(IERC20(_token), beneficiary(), amount);
    }

    function releasedAmount(address token, uint64 timestamp) public view virtual returns (uint256) {
        return _releaseSchedule(IERC20(token).balanceOf(address(this)) + released(), timestamp);
    }

    /**
     * @dev Calculates the amount of tokens that has already released. Default implementation is a linear curve.
     */
    function _releaseSchedule(uint256 totalAllocation, uint64 timestamp) internal view virtual returns (uint256) {
        if (timestamp < start()) {
            return 0;
        } else if (timestamp > start() + duration()) {
            return totalAllocation;
        } else {
            uint256 elapsedTime = 0;
            for (uint256 i = 0; i < _unlockTimestamps.length; i++) {
                if (timestamp >= _unlockTimestamps[i]) {
                    elapsedTime++;
                } else {
                    break;
                }
            }
            return (totalAllocation * elapsedTime) / _unlockTimestamps.length;
        }
    }
}
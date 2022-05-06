// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;
import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

contract UniswapV2Factory is IUniswapV2Factory {
    address public feeTo;//收税地址
    address public feeToSetter;//设置feeTo的地址

    mapping(address => mapping(address => address)) public getPair; //token0，token1 映射的 交易对的地址
    address[] public allPairs;//记录所有的交易对地址，上面的映射已经记录但不能遍历

    event PairCreated(address indexed token0, address indexed token1, address pair, uint); //记录创建交易对的事件
    //部署地址，设置一个初始feeToSetter
    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }
    //返回所有交易对长度
    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }
    //创建交易对，返回交易对地址
    function createPair(address tokenA, address tokenB) external returns (address pair) {

        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        //对比tokenA，tokenB，给（token0，token1）赋值
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');

        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // token0，token1的交易对必须是新的

        bytes memory bytecode = type(UniswapV2Pair).creationCode;// // 使用type(合约名称).creationCode 方法获得该合约编译之后的字节码
        // abi.encodePacked()     编码打包
        // keccak256              Solidity 内置加密Hash方法
        // keccak256(abi.encodePacked(a, b))是计算keccak256(a, b)更明确的方式
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        // 内联汇编
        // mload(bytecode)          返回长度
        // create2                  新的操作码 （opcode 操作码是程序的低级可读指令, 所有操作码都具有对应的十六进制值）
        assembly {
            //通过create2部署合约，并且传入参数，返回交易对地址pair
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        IUniswapV2Pair(pair).initialize(token0, token1);// 调用pair合约的初始化方法，传入参数tA tB
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; //两个方向映射都设置
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}

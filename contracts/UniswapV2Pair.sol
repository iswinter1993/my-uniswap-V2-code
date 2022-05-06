// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;
import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

//配对合约
contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath  for uint;
    using UQ112x112 for uint224;
    //最小流动性，增加攻击成本
    /*
        公式可确保流动性池份额的价值永远不会低于该池中储备的几何平均值。但是，流动资金池份
        额的价值有可能随着时间的推移增长⻓，这可以通过累积交易费用或通过向流动资金池的“捐赠”来实
        现。从理论上讲，这可能导致最小数量的流动性池份额（1e-18池份额）的价值过高，以至于小型流动
        性提供者无法提供任何流动性。
        为了缓解这种情况，Uniswap v2会刻录创建的第一个1e-15（0.000000000000001）池份额（池份额
        最小数量的1000倍），然后将它们发送到零地址，而不是发送到铸造者。对于几乎所有令牌对来说，
        这应该是微不足道的成本。但是，这大大增加了上述攻击的成本。为了将流动资金池份额的价值提
        到100美元，攻击者需要向该池捐赠100,000美元，该资金将永久锁定为流动资金。
        ）
    */
    uint public constant MINIMUM_LIQUIDITY = 10**3;
    //transfer方法通过bytes打包 ，keccak256编译成哈希值，再通过bytes4打包生成16进制4位数的值
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    address public factory;//工厂合约
    address public token0;
    address public token1;

    uint112 private reserve0;           // uses single storage slot, accessible via getReserves 储存量0
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves 储存量1
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves // 时间戳

    uint public price0CumulativeLast;//价格0,最后累计值。在周边合约的预言机中有使用到
    uint public price1CumulativeLast;
    // 储备金0 * 储备金1，截至最近一次流动性事件后
    // 在最近一次流动性事件之后的k值 恒定乘积做市商     x * y = k     上次收取费用的增长
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event
    // 修饰符：防止重入的开关
    uint private unlocked = 1;
    //防止重入
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }
    // 获取储备量
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }
    // 私有安全的发送函数
    function _safeTransfer(address token, address to, uint value) private {
        //call方法可以调用合约中的方法
        // 在一个合约调用另一个合约中，可以通过接口合约调用
        // 没有接口合约的情况下，可以使用底层的call方法，
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        // 校验上面方法调用的结果
        // bool 为true && （data的长度为0 || abi反解码之后的bool = true）
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    //同步
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor() public {
        //配对合约都是工厂合约调用的 ，所以msg.sender = 工厂合约的地址
        factory = msg.sender;
    }

    // // 初始化部署合约，由工厂合约来完成
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    // update reserves and, on the first call per block, price accumulators
    //更新储备量，并在每个区块首次调用时，累积价格
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        // 校验余额0和余额1小等于uint112的最大数值，防止溢出
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');
        // block.timestamp               区块时间戳
        // block.timestamp % 2**32       模上2**32得到余数为32位的uint32的数值
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        // 计算时间流逝。当前时间戳 - 最近一次流动性事件的时间戳
        // （目的是为了校验更改的区块是过去时间已存在的）
        uint32 timeElapsed = blockTimestamp - blockTimestampLast;
        // 满足条件 （ 间隔时间 > 0 && 储备量0,1 != 0 ）
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // 最后累计的价格0 = UQ112(储备量1 / 储备量0) * 时间流逝
            // 最后累计的价格1 = UQ112(储备量0 / 储备量1) * 时间流逝
            // 计算得到的值在用于价格预言机中使用
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed; //预言代币价格
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        // 将余额0和余额1分别赋值给储备量0和储备量1
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    //返回铸造费开关
    // 如果收取费用，铸造流动性相当于1/6的增长sqrt（k）
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IUniswapV2Factory(factory).feeTo();//获取收税地址
        feeOn = feeTo != address(0);//定义个bool，如果feeTo地址为0，表示不收费
        uint _kLast = kLast; // gas savings 恒定乘积做市商     x * y = k     上次收取费用的增长
        if (feeOn) {//计算税收
            if (_kLast != 0) {
                // 以下算法在白皮书中有体现
                /**
                *    Sm = [ (sqrt(k2) - sqrt(k1)) / 5*sqrt(k2) + sqrt(k1) ] * S1
                */
                // S1表示在t1时间的流通股总数（totalSupply）
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1)); // K2
                uint rootKLast = Math.sqrt(_kLast);                     // K1
                if (rootK > rootKLast) {
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast)); // 分子
                    uint denominator = rootK.mul(5).add(rootKLast);         // 分母
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);             // 如果计算得出的流动性 > 0，将流动性铸造给feeTo地址
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    //to : 这个地址表示计算处理的流动性代币数额将给到这个地址
    function mint(address to) external lock returns (uint liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings 获取储备量
        // 根据ERC20合约，可以获得token0和token1当前合约地址中所拥有的余额
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        uint amount0 = balance0.sub(_reserve0);//数量 = 余额 - 储备量
        uint amount1 = balance1.sub(_reserve1);
        // 计算流动性，根据是否开启收税给相应地址发送协议费用
        bool feeOn = _mintFee(_reserve0, _reserve1);
         //获取totalSupply,必须在此处定义，因为totalSupply可以在mintFee中更新
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            //流动性 = (数量0 * 数量1)的平方根 - 最小流动性1000
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
             //在总量为0的初始状态,永久锁定最低流动性(将它们发送到零地址，而不是发送到铸造者。)
           _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
             //流动性 = 最小值 (amount0 * _totalSupply / _reserve0) 和 (amount1 * _totalSupply / _reserve1)
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
         // 铸造流动性发送给to地址
        _mint(to, liquidity);
        // 更新储备量
        _update(balance0, balance1, _reserve0, _reserve1);
        //如果铸造费开关为true, k值 = 储备0 * 储备1
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date 做市商
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
     // 合约销毁（外部调用）
    /*
        销毁方法总结：
          1. 路由合约带入一个准备销毁多少流动性的数额，将这个数额发送给pair合约
          2. pair计算出准备销毁的流动性数额占供应的流动性总量的比例
          3. pair合约中的t0 和 t1 的余额 乘以比例，就分别得出需要取出的t0和t1的值为a0和a1
          4. 将计算得到的a0和a1的值安全发送给to地址
          5. 更新储备量
          6. 如果收取协议费用，需要更新恒定乘积
          7. 触发销毁事件
    */
    function burn(address to) external lock returns (uint amount0, uint amount1) {
         // 获取储备量
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        address _token0 = token0;                                // gas savings
        address _token1 = token1;  
        // 获取当前调用者的地址在token0和token1中的余额    
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        // 获得当前地址的流动性（当前合约地址是不应该有余额的，因为在铸造配对合约过程中，最后是将计算到的流动性赋值给了传入的to地址）
        // 这个流动性的实际值是从路由合约的 移除流动性方法removeLiquidity 中发送过来的（将调用者的流动性发送给pair合约）
        // removeLiquidity  ==》  IUniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity);
        uint liquidity = balanceOf[address(this)];//获取当前合约的流动量，
        // 计算协议费用
        bool feeOn = _mintFee(_reserve0, _reserve1);
        // 节省gas，必须在此处定义，因为totalSupply可以在_mintFee中更新
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        // 使用余额确保按比例分配（取出的数值 = 我所拥有的流动性占比 * 总余额）
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        _burn(address(this), liquidity);
        // 调用安全发送方法，分别将t0取出的amount0和t1取出的amount1发送给to地址
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        // 取出当前地址在合约上t0和t1的余额
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        // 如果开启了收取协议费用，则 kLast = x * y
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
     // 要取出的数额0
     // 要取出的数额1
      // 取出存放的地址
      // 存储的函数参数，只读。外部函数的参数（不包括返回参数）被强制为calldata
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        // 校验取出数额0 或者 数额1其中一个大于 0
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        // 获取储备量0和储备量1
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
         // 校验取出数额0小于储备量0  &&  取出数额1小于储备量1
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        // _token {0,1}的范围，避免了堆栈太深的错误
        { // scope for _token{0,1}, avoids stack too deep errors
            address _token0 = token0;
            address _token1 = token1;
            // 校验to地址不能是t0和t1的地址
            require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
            // 确认取出数额大于0 ，就分别将t0和t1的数额安全发送到to地址
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
            // 如果data长度大于0 ，调用to地址的接口
            if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);// 闪电贷
            // 获取最新的t0和t1余额
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }
        
        // 根据取出的储备量、原有储备量以及最新的余额，反推得到输入的数额
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        // 确保任意一个输入数额大于0
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
            // 调整后的余额 = 最新余额 - 扣税金额 （相当于乘以997/1000）
            uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
            uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
            // 校验是否进行了扣税计算
            require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}

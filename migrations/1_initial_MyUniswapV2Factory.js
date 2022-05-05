const MyUniswapV2Factory = artifacts.require("MyUniswapV2Factory");

module.exports = function (deployer) {
  deployer.deploy(MyUniswapV2Factory);
};

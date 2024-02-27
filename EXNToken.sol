// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import "../openzeppelin/ERC20/ERC20.sol";
import "../openzeppelin/access/Ownable.sol";
import "../openzeppelin/utils/math/SafeMath.sol";

contract EXNToken is ERC20, Ownable {
    //  используем  SafeMath для типа данных uint256 чтобы избежать возможного переполнения
    using SafeMath for uint256;

    // указываем Описание токена как неизменяемую константу
    string public constant description = "";
    // указываем  лого тип токена сохроненного в ipfs  в виде картинки
    string public constant logoURI = "https://bafkreidnj54yqpvvjytj35k6izmjcbjzge3azd3j2ovmx36l3pr7qmzagy.ipfs.nftstorage.link";
    
    // добавляем возможность использования ролей администраторов для управления контрактом
    mapping(address => bool) public admins;

    // константы
    uint256 public constant TOKEN_LIMIT_TOTAL_SUPPLY = 500000000*(10**8);

    // создаем события контракта на каждое значимое действие
    event Mint(address indexed to, uint256 amount);
    event Burn(address indexed from, uint256 amount);
    event AddAdmin(address indexed admin);
    event RemoveAdmin(address indexed admin);
    event TransferOwnership(address indexed newOwner);
   

    // Создаем модификаторы доступа

    modifier onlyAdmin() {
        require(admins[msg.sender], "Caller is not the admin");
        _;
    }

    modifier nonZeroAddress(address addr) {
        require(addr != address(0), "Invalid address: zero address not allowed");
        _;
    }

     modifier adminIsOwner(address admin) {
        require(admin != owner(), "Caller is owner: Admin is owner address");
        _;
     }

    /** 
        @notice Указываем в конструкторе наименование и символ токена, а так же  передаем значение  initialSupply
        @param initialSupply определения базового начального количества для минта токена на кошелек owner
    */
    constructor(uint256 initialSupply) ERC20("Expoin", "EXN") {
            _mint(msg.sender, initialSupply * (1 ** uint256(decimals())));
            addAdmin(owner());
    }

    /** 
        @notice Минт токена переопределенная из ERC20
        @param to на какой кошелек отправяться заминченные токены
        @param amount сумма для минта
    */
    function mint(address to, uint256 amount) public onlyAdmin nonZeroAddress(to) {
        require(amount > 0, "EXNToken: amount must be greater than zero");
        require(totalSupply().add(amount) <= TOKEN_LIMIT_TOTAL_SUPPLY, "EXNToken: total supply limit exceeded");
        _mint(to, amount);
        emit Mint(to, amount);
    }

    /** 
        @notice Сжигание токена переопределенная из ERC20
        @param amount сумма для сжигания, сжигаются токены только с кошелька владельца
    */
    function burn(uint256 amount) public onlyOwner {
        require(amount > 0, "EXNToken: amount must be greater than zero");
        _burn(owner(), amount);
        emit Burn(owner(), amount);
    }

    /** 
        @notice Передача главных прав на токен другому кошельку
        @param newOwner адрес нового кошелька владельца
    */
    function transferOwnership(address newOwner) public override onlyOwner nonZeroAddress(newOwner){
        super.transferOwnership(newOwner);
        emit TransferOwnership(newOwner);
    }

    /** 
        @notice Добавление кошельку роли админа
        @param _admin адрес новго админа
    */
    function addAdmin(address _admin) public onlyOwner nonZeroAddress(_admin){
        require(admins[_admin] == false, "EXNToken: admin address already exists");
        admins[_admin] = true;
        emit AddAdmin(_admin);
    }

    /** 
        @notice Удаление кошелька из админов 
        @param _admin адрес удаляемого админа
    */
    function removeAdmin(address _admin) public onlyOwner nonZeroAddress(_admin) adminIsOwner(_admin) {
        require(admins[_admin], "EXNToken: admin address does not exist");
        admins[_admin] = false;
        emit RemoveAdmin(_admin);
    }

    /* 
        Переопределяем renounceOwnership что бы случайно не лишиться доступа к контракту, 
        при необходимости укажем смену прав на 0x0 кошелек простой передачей прав
    */
    function renounceOwnership() public virtual override onlyOwner {}

}
pragma solidity ^0.4.23;

import "./Token.sol";
import "./Utils.sol";
import "./ECVerify.sol";
import "./SecretRegistry.sol";
/*
合约依据原理:
https://raiden.network/101.html

新版本合约主要解决以下几个问题：
1. 在不关闭通道的情况下取现
2. 合作关闭通道，不用等待
3. 加上惩罚不诚实中间路由节点机制。

主要考虑以下安全问题:
1. 双方不能共谋侵占 tokenNetwork 中的 token
2. AB 双方无论谁提供了错误的,虚假的数据不能给对方造成损害
3. AB 双方无论谁提供了错误的,虚假的数据不能给自己带来不当收益
4. AB 双方无论谁都不能因为不配合,不作为而给对方造成损害.
    比如因为某个人不配合而造成 channel 无法 settle,

优化问题:
1. 有更节省 gas 的写法?
2. 有逻辑更清晰简单的写法?
3. 其他更好的思路

假设前提:
TokenNetwork 是要形成一个关于某个 token 的链下交易网络.
1. token 本身如果有问题,那么 tokennetwork 就毫无价值,必须重新创建了.
2. 任何一个 token 的totalSupply 不可能大于 uint256,实际上应该是远小于这个数字
3. 正常交易积累的金额不应该很大,也就是不会出现transferAmount+deposit 超过 uint256的情况. 如果出现这个情况,那一定是双方合作诈骗.
*/

/*
204存在严重 bug:
惩罚 locksroot 是没有意义的,因为我们允许交易是并发的.
假设一笔交易
F-A-B-C 金额200token
G-A-B-C 金额10token
同时进行,假设 B 收到第一笔交易以后,通过 refund 声明放弃,但是随后收到了来自 A 的第二笔交易.
假设 第一笔交易的 locksroot=l(200),第二笔交易的locksroot=l(200,10)
B 声明放弃了 l(200),但是有A有效签名的l(200,10)并未声明放弃,因此 B 可以在其他地方搞到200token 那笔交易的密码,然后将l(200,10)解锁
*/

/*
本版本限制:
只能一次解锁一个锁,支持委托解锁.
委托解锁前提是:
必须自己知道密码,否则不应该委托.
*/
contract TokenNetwork is Utils {

    /*
     *  Data structures
     */

    string constant public contract_version = "0.3._";
    /*
    用于惩罚不诚实节点,让自己的nonce最大, transferamount 为0,locksroot 为0,
    */
    bytes24 constant public invalid_balance_hash = bytes24(keccak256(abi.encodePacked(bytes32(0), uint256(0))));

    // Instance of the token used as digital currency by the channels
    Token public token;
    // Instance of SecretRegistry used for storing secrets revealed in a mediating transfer.
    SecretRegistry public secret_registry;
    /*
    留给惩罚对手的时间,这个时间专门开辟出来,settle time 之后,可以提交证据而不用担心对手是在临近 settle 之时提交 updatetransfer 和 进行 unlock,
    从而导致自己没有机会提交惩罚证据.
    这个时间多少合适呢?100块?
    */
    uint64 constant public punish_block_number = 10;
    // Chain ID as specified by EIP155 used in balance proof signatures to avoid replay attacks
    uint256 public chain_id;
    // Channel identifier is sha3(participant1,participant2,tokenNetworkAddress)
    mapping(bytes32 => Channel) public channels;

    struct Participant {
        // Total amount of token transferred to this smart contract
        uint256 deposit;
        /*
        nonce,locksroot,transferred_amount 的 hash
        主要是出于节省 gas 的目的,真正的 nonce,locksroot,transferred_amount都通过参数传递,可以较大幅度降低 gas
        */
        //bytes32 balance_hash;

        /*
        locksroot,transferred_amount 的 hash
        主要是出于节省 gas 的目的,真正的locksroot,transferred_amount都通过参数传递,可以较大幅度降低 gas
        */
        bytes24 balance_hash;
        //交易编号
        uint64 nonce;

        /*
        解锁结果
        */
        mapping(bytes32 => bool) unlocked_locks;
    }

    struct Channel {
        /*
        通道结算等待时间
        */
        uint64 settle_timeout;
        /*
        通道 settle block number.
        */
        uint64 settle_block_number;
        /*
        通道打开时间,主要用于防止重放攻击
        每个通道的真实 id, 相当于 channel id+open_blocknumber
        */
        uint64 open_block_number;
        /*
        不关心是谁关闭了通道,关闭通道一方也可以再次更新证据,只要他能提供更新的 nonce 就可以了
        目前设计是允许 close一方再次 update balance proof.
        address closing_participant;
        */

        // Channel state
        // 1 = open, 2 = closed
        // 0 = non-existent or settled
        uint8 state;
        mapping(address => Participant) participants;
    }

    /*
*  Events
*/
    event ChannelOpened(
        bytes32 indexed channel_identifier,
        address participant1,
        address participant2,
        uint256 settle_timeout
    );

    event ChannelNewDeposit(
        bytes32 indexed channel_identifier,
        address participant,
        uint256 total_deposit
    );
    //如果改变 balance_hash, 那么应该通过 event 把balance_hash 中的两个变量都暴露出来.
    event ChannelClosed(bytes32 indexed channel_identifier, address closing_participant, bytes32 locksroot, uint256 transferred_amount);
    //如果改变 balance_hash, 那么应该通过 event 把两个个变量都暴露出来.
    event ChannelUnlocked(
        bytes32 indexed channel_identifier,
        address payer_participant,
        bytes32 lockhash, //解锁的lock
        uint256 transferred_amount
    );
    //如果改变 balance_hash, 那么应该通过 event 把三个变量都暴露出来.
    event BalanceProofUpdated(
        bytes32 indexed channel_identifier,
        address participant,
        bytes32 locksroot,
        uint256 transferred_amount
    );

    event ChannelSettled(
        bytes32 indexed channel_identifier,
        uint256 participant1_amount,
        uint256 participant2_amount
    );
    event ChannelCooperativeSettled(
        bytes32 indexed channel_identifier,
        uint256 participant1_amount,
        uint256 participant2_amount
    );
    event ChannelWithdraw(
        bytes32 indexed channel_identifier,
        address participant1,
        uint256 participant1_balance,
        address participant2,
        uint256 participant2_balance
    );

    modifier settleTimeoutValid(uint64 timeout) {
        require(timeout >= 6 && timeout <= 2700000);
        _;
    }
    /*
   *  Constructor
   */

    constructor(address _token_address, address _secret_registry, uint256 _chain_id)
    public
    {
        require(_token_address != 0x0);
        require(_secret_registry != 0x0);
        require(_chain_id > 0);
        require(contractExists(_token_address));
        require(contractExists(_secret_registry));

        token = Token(_token_address);

        secret_registry = SecretRegistry(_secret_registry);
        chain_id = _chain_id;

        // Make sure the contract is indeed a token contract
        require(token.totalSupply() > 0);
    }

    /*
    允许任何人调用,多次调用.
    创建通道:
    1. 允许任意两个不同有效地址之间创建通道
    2. 两地址之间不能有多个通道
    */
    function openChannel(address participant1, address participant2, uint64 settle_timeout)
    settleTimeoutValid(settle_timeout)
    public
    {
        bytes32 channel_identifier;
        require(participant1 != 0x0);
        require(participant2 != 0x0);
        require(participant1 != participant2);
        channel_identifier = getChannelIdentifier(participant1, participant2);
        Channel storage channel = channels[channel_identifier];
        /*
        保证channel没有被创建过
        */
        require(channel.state == 0);
        // Store channel information
        channel.settle_timeout = settle_timeout;
        channel.open_block_number = uint64(block.number);
        // Mark channel as opened
        channel.state = 1;

        emit ChannelOpened(channel_identifier, participant1, participant2, settle_timeout);
    }
    /*
    open and deposit 合在一起,节省 gas
    */
    function openChannelWithDeposit(address participant, address partner, uint64 settle_timeout, uint256 deposit)
    settleTimeoutValid(settle_timeout)
    public
    {
        bytes32 channel_identifier;
        require(participant != 0x0);
        require(partner != 0x0);
        require(participant != partner);
        channel_identifier = getChannelIdentifier(participant, partner);
        Channel storage channel = channels[channel_identifier];
        Participant storage participant_state = channel.participants[participant];
        /*
        保证channel没有被创建过
        */
        require(channel.state == 0);

        // Store channel information
        channel.settle_timeout = settle_timeout;
        channel.open_block_number = uint64(block.number);
        // Mark channel as opened
        channel.state = 1;
        require(token.transferFrom(msg.sender, address(this), deposit));
        participant_state.deposit = deposit;
        emit ChannelOpened(channel_identifier, participant, partner, settle_timeout);
    }
    /*
    必须在通道 open 状态调用,可以重复调用多次,任何人都可以调用.
    */
    function deposit(address participant, address partner, uint256 amount)
    public
    {
        require(amount > 0);
        uint256 total_deposit;
        bytes32 channel_identifier;
        channel_identifier = getChannelIdentifier(participant, partner);
        Channel storage channel = channels[channel_identifier];
        Participant storage participant_state = channel.participants[participant];
        total_deposit = participant_state.deposit;

        // Do the transfer
        require(token.transferFrom(msg.sender, address(this), amount));
        require(channel.state == 1);
        // Update the participant's channel deposit
        total_deposit += amount;
        participant_state.deposit = total_deposit;

        emit ChannelNewDeposit(channel_identifier, participant, total_deposit);
        //如果 token 可能的 totalSupply 大于 uint256,说明这个 token 分文不值,分文不值的 token 发生什么都无所谓.
        //require(participant_state.deposit >= added_deposit);
        //防止溢出,有必要么?我是想不到原因.
        //require(channel_deposit >= participant_state.deposit);
        //require(channel_deposit >= partner_state.deposit);
    }
    /*
    功能:在不关闭通道的情况下提现,
    任何人都可以调用,调用一次相当于新创建了通道,所以无法重放攻击

    一旦一方提出 withdraw, 实际上和提出 cooperative settle 效果是一样的,就是不能再进行任何交易了.
    必须等待 withdraw 完成才能重置数据,重新开始交易
    */
    function withDraw(
        address participant1,
        uint256 participant1_balance,
        uint256 participant1_withdraw,
        address participant2,
        uint256 participant2_balance,
        uint256 participant2_withdraw,
        bytes participant1_signature,
        bytes participant2_signature
    )
    public
    {
        uint256 total_deposit;
        bytes32 channel_identifier;
        channel_identifier = getChannelIdentifier(participant1, participant2);
        Channel storage channel = channels[channel_identifier];
        require(channel.state == 1);
        //验证发送方签名
        bytes32 message_hash = keccak256(abi.encodePacked(
                participant1,
                participant1_balance,
                participant2,
                participant2_balance,
                participant1_withdraw,
                channel_identifier,
                channel.open_block_number,
            //address(this),
                chain_id
            ));
        require(participant1 == ECVerify.ecverify(message_hash, participant1_signature));
        //验证接收方签名
        message_hash = keccak256(abi.encodePacked(
                participant1,
                participant1_balance,
                participant2,
                participant2_balance,
                participant1_withdraw,
                participant2_withdraw,
                channel_identifier,
                channel.open_block_number,
            // address(this),
                chain_id
            ));
        require(participant2 == ECVerify.ecverify(message_hash, participant2_signature));
        Participant storage participant1_state = channel.participants[participant1];
        Participant storage participant2_state = channel.participants[participant2];
        //The sum of the provided deposit must be equal to the total available deposit
        total_deposit = participant1_state.deposit + participant2_state.deposit;
        require(participant1_balance <= total_deposit);
        require(participant2_balance <= total_deposit);
        require((participant1_balance + participant2_balance) == total_deposit);
        /*
        谨慎一点,应该先扣钱再转账, ERC20TOKEN 可能是一个以太坊 Wrapper. 否则这就是一个 the dao 攻击
        */
        require(participant1_withdraw <= participant1_balance);
        require(participant2_withdraw <= participant2_balance);
        participant1_state.deposit = participant1_balance - participant1_withdraw;
        participant2_state.deposit = participant2_balance - participant2_withdraw;

        //相当于 通道 settle 有新开了.老的签名都作废了.
        channel.open_block_number = uint64(block.number);

        // Do the token transfers
        if (participant1_withdraw > 0) {
            require(token.transfer(participant1, participant1_withdraw));
        }
        if (participant2_withdraw > 0) {
            require(token.transfer(participant2, participant2_withdraw));
        }

        emit ChannelWithdraw(channel_identifier, participant1, participant1_balance, participant2, participant2_balance);

    }
    /*
    只能是通道参与方调用,只能调用一次,必须是在通道打开状态调用.
    */
    function closeChannel(
        address partner,
        uint256 transferred_amount,
        bytes32 locksroot,
        uint64 nonce,
        bytes32 additional_hash,
        bytes signature
    )
    public
    {
        bytes32 channel_identifier;
        address recovered_partner_address;
        channel_identifier = getChannelIdentifier(msg.sender, partner);
        Channel storage channel = channels[channel_identifier];
        require(channel.state == 1);
        // Mark the channel as closed and mark the closing participant
        channel.state = 2;
        // This is the block number at which the channel can be settled.
        channel.settle_block_number =channel.settle_timeout+ uint64(block.number);
        // Nonce 0 means that the closer never received a transfer, therefore never received a
        // balance proof, or he is intentionally not providing the latest transfer, in which case
        // the closing party is going to lose the tokens that were transferred to him.
        if (nonce > 0) {
            Participant storage partner_state = channel.participants[partner];
            recovered_partner_address = recoverAddressFromBalanceProof(
                channel_identifier,
                transferred_amount,
                locksroot,
                nonce,
                channel.open_block_number,
                additional_hash,
                signature
            );
            require(partner == recovered_partner_address);
            partner_state.balance_hash = calceBalanceHash(transferred_amount, locksroot);
            partner_state.nonce = nonce;
        }
        emit ChannelClosed(channel_identifier, msg.sender, locksroot, transferred_amount);
    }
    /*
    任何人都可以调用,可以调用多次,只要在有效期内.
    包括 closing 方和非 close 方都可以反复调用在,只要能够提供更新的 nonce 即可.
    */
    function updateBalanceProofDelegate(
        address partner,
        address participant,
        uint256 transferred_amount,
        bytes32 locksroot,
        uint64 nonce,
        bytes32 additional_hash,
        bytes partner_signature,
        bytes participant_signature
    )
    public
    {
        bytes32 channel_identifier;
        uint64 settle_block_number;
        channel_identifier = getChannelIdentifier(partner, participant);
        Channel storage channel = channels[channel_identifier];
        Participant storage partner_state = channel.participants[partner];
        require(channel.state == 2);
        /*
        被委托人只能在结算时间的后一半进行
        */
        settle_block_number=channel.settle_block_number;
        require( settle_block_number>= block.number);
        require(  block.number>=settle_block_number-channel.settle_timeout/2);
        require(nonce > partner_state.nonce);

        require(participant == recoverAddressFromBalanceProofUpdateMessage(
            channel_identifier,
            transferred_amount,
            locksroot,
            nonce,
            channel.open_block_number,
            additional_hash,
            partner_signature,
            participant_signature
        ));
        require(partner == recoverAddressFromBalanceProof(
            channel_identifier,
            transferred_amount,
            locksroot,
            nonce,
            channel.open_block_number,
            additional_hash,
            partner_signature
        ));
        partner_state.balance_hash = calceBalanceHash(transferred_amount, locksroot);
        partner_state.nonce = nonce;
        emit BalanceProofUpdated(channel_identifier, partner, locksroot, transferred_amount);
    }
    /*
   只能通道参与方调用,不限制 close 和非 close 方,可以调用多次,只要在有效期内.
   包括 closing 方和非 close 方都可以反复调用在,只要能够提供更新的 nonce 即可.
   */
    function updateBalanceProof(
        address partner,
        uint256 transferred_amount,
        bytes32 locksroot,
        uint64 nonce,
        bytes32 additional_hash,
        bytes partner_signature
    )
    public
    {
        bytes32 channel_identifier;
        channel_identifier = getChannelIdentifier(partner, msg.sender);
        Channel storage channel = channels[channel_identifier];
        Participant storage partner_state = channel.participants[partner];
        require(channel.state == 2);
        require(channel.settle_block_number >= block.number);
        require(nonce > partner_state.nonce);

        require(partner == recoverAddressFromBalanceProof(
            channel_identifier,
            transferred_amount,
            locksroot,
            nonce,
            channel.open_block_number,
            additional_hash,
            partner_signature
        ));
        partner_state.balance_hash = calceBalanceHash(transferred_amount, locksroot);
        partner_state.nonce = nonce;
        emit BalanceProofUpdated(channel_identifier, partner, locksroot, transferred_amount);
    }
    /*
    存在第三方和对手串谋 unlock 的可能,导致委托人损失所有金额
    所以必须有委托人签名
    */
    function unlockDelegate(
        address partner,
        address participant,
        uint256 transferred_amount,
        uint256 expiration,
        uint256 amount,
        bytes32 secret_hash,
        bytes merkle_proof,
        bytes participant_signature
    ) public {
        bytes32 message_hash;
        bytes32 channel_identifier;
        channel_identifier = getChannelIdentifier(partner, participant);
        Channel storage channel = channels[channel_identifier];
        /*
        验证授权签名有效
        */
        message_hash = keccak256(abi.encodePacked(
            msg.sender,
            expiration,
            amount,
            secret_hash,
            channel_identifier,
            channel.open_block_number,
            chain_id));
        require(participant == ECVerify.ecverify(message_hash, participant_signature));
        /*
        真正的去 unlock
        */
        unlockInternal(partner, participant, transferred_amount, expiration, amount, secret_hash, merkle_proof);
    }
    /*
    只允许通道参与方可以调用,要在有效期内调用.通道状态必须是关闭,
    并且必须在 settle 之前来调用.只能由通道参与方来调用.
    */
    function unlock(
        address partner,
        uint256 transferred_amount,
        uint256 expiration,
        uint256 amount,
        bytes32 secret_hash,
        bytes merkle_proof
    ) public
    {
        unlockInternal(partner, msg.sender, transferred_amount, expiration, amount, secret_hash, merkle_proof);
    }

    function unlockInternal(
        address partner,
        address participant,
        uint256 transferered_amount,
        uint256 expiration,
        uint256 amount,
        bytes32 secret_hash,
        bytes merkle_proof
    )
    internal
    {
        bytes32 channel_identifier;
        bytes32 lockhash_hash;
        bytes32 lockhash;
        uint256 reveal_block;
        bytes32 locksroot;
        require(merkle_proof.length > 0);
        channel_identifier = getChannelIdentifier(partner, participant);
        Channel storage channel = channels[channel_identifier];
        Participant storage partner_state = channel.participants[partner];
        /*
        通道状态正确
        */
        require(channel.settle_block_number >= block.number);
        require(channel.state == 2);

        /*
        对应的锁已经注册过,并且没有过期.
        */
        reveal_block = secret_registry.getSecretRevealBlockHeight(secret_hash);
        require(reveal_block > 0 && reveal_block <= expiration);

        /*
        证明这个所包含在 locksroot 中
        */
        lockhash = keccak256(abi.encodePacked(expiration, amount, secret_hash));
        locksroot = computeMerkleRoot(lockhash, merkle_proof);
        require(partner_state.balance_hash == calceBalanceHash(transferered_amount, locksroot));


        //不允许重复 unlock 同一个锁,同时 nonce 变化以后还可以 再次 unlock 同一个锁
        lockhash_hash = keccak256(abi.encodePacked(partner_state.nonce, lockhash));

        require(partner_state.unlocked_locks[lockhash_hash] == false);
        partner_state.unlocked_locks[lockhash_hash] = true;


        /*
        会不会溢出呢? 两人持续交易?
        正常来说,不会,
        但是如果是恶意的会溢出,但是溢出对于 自身 也没好处啊
        */
        transferered_amount += amount;
        /*
       注意transferered_amount已经更新了,
        */
        partner_state.balance_hash = calceBalanceHash(transferered_amount, locksroot);
        emit ChannelUnlocked(channel_identifier, partner, lockhash, transferered_amount);
    }
    /*

        /// @notice punish partner unlock a obsolete lock which he has annouced to abandon .
        // Anyone can call punishObsoleteUnlock  on behalf of a channel participant.
        /// @param channel_identifier The channel identifier - mapping key used for `channels`.
        /// @param beneficiary Address of the participant who owes the locked tokens.
        /// //@param expiration_block Block height at which the lock expires.
        /// @param locked_amount Amount of tokens that the locked transfer values.
        /// @param hashlock hash of a preimage used in a HTL Transfer
        /// @param additional_hash Computed from the message. Used for message authentication.
        /// @param signature signature of partner who has annouced to abandon this transfer,whether or not he knows the password.
        */

    /*
    给 punish 一方留出了专门的 punishBlock 时间,punish 一方可以选择在那个时候提交证据,也可以在这之前.
    如果能够提供 old beneficiary_transferred_amount,也就是加 unlock 之前的,可以将unlocked_locksroot中的删除,从而再节省 gas, 不过意义好像并不大.
    */
    function punishObsoleteUnlock(
        address beneficiary,
        address cheater,
        bytes32 lockhash,
        bytes32 additional_hash,
        bytes cheater_signature)
    public
    {
        bytes32 channel_identifier;
        bytes32 balance_hash;
        bytes32 lockhash_hash;
        channel_identifier = getChannelIdentifier(beneficiary, cheater);
        Channel storage channel = channels[channel_identifier];
        require(channel.state == 2);
        Participant storage beneficiary_state = channel.participants[beneficiary];
        balance_hash = beneficiary_state.balance_hash;

        // Check that the partner is a channel participant.
        // An empty locksroot means there are no pending locks
        require(balance_hash != 0);
        /*
        the cheater provides his signature of lockhash to annouce that he has already abandon this transfer.
        */
        require(cheater == recoverAddressFromUnlockProof(
            channel_identifier,
            lockhash,
            uint64(channel.open_block_number),
            additional_hash,
            cheater_signature
        ));
        Participant storage cheater_state = channel.participants[cheater];

        /*
        证明这个 lockhash 被对方提交了.
        */
        lockhash_hash = keccak256(abi.encodePacked(beneficiary_state.nonce, lockhash));
        require(beneficiary_state.unlocked_locks[lockhash_hash]);
        delete beneficiary_state.unlocked_locks[lockhash_hash];
        /*
        punish the cheater.
        */
        beneficiary_state.balance_hash = invalid_balance_hash;
        beneficiary_state.nonce = 0xffffffffffffffff;
        beneficiary_state.deposit = beneficiary_state.deposit + cheater_state.deposit;
        cheater_state.deposit = 0;
    }
    /*
    任何人都可以调用,只能调用一次
    */
    function settleChannel(
        address participant1,
        uint256 participant1_transferred_amount,
        bytes32 participant1_locksroot,
        address participant2,
        uint256 participant2_transferred_amount,
        bytes32 participant2_locksroot
    )
    public
    {
        uint256 participant1_amount;
        uint256 total_deposit;
        bytes32 channel_identifier;
        channel_identifier = getChannelIdentifier(participant1, participant2);
        Channel storage channel = channels[channel_identifier];
        // Channel must be closed
        require(channel.state == 2);

        /*
         Settlement window must be over
         真正能 settle 并不是 settle block number, 还要加上 punish_block_number,
         这是给对手提交 punish 证据专门留出的时间.
         */
        require(channel.settle_block_number + punish_block_number < block.number);

        Participant storage participant1_state = channel.participants[participant1];
        Participant storage participant2_state = channel.participants[participant2];
        /*
        验证提供的参数是有效的
        */
        require(participant1_state.balance_hash == calceBalanceHash(participant1_transferred_amount, participant1_locksroot));
        require(participant2_state.balance_hash == calceBalanceHash(participant2_transferred_amount, participant2_locksroot));

        total_deposit = participant1_state.deposit + participant2_state.deposit;

        participant1_amount = (
        participant1_state.deposit
        + participant2_transferred_amount
        - participant1_transferred_amount
        );
        // There are 2 cases that require attention here:
        // case1. If participant1 does NOT provide a balance proof or provides an old balance proof
        // case2. If participant2 does NOT provide a balance proof or provides an old balance proof
        // The issue is that we need to react differently in both cases. However, both cases have
        // an end result of participant1_amount > total_available_deposit. Therefore:

        // case1: participant2_transferred_amount can be [0, real_participant2_transferred_amount)
        // This can trigger an underflow -> participant1_amount > total_available_deposit
        // We need to make participant1_amount = 0 in this case, otherwise it can be
        // an attack vector. participant1 must lose all/some of its tokens if it does not
        // provide a valid balance proof.
        if (
            (participant1_state.deposit + participant2_transferred_amount) < participant1_transferred_amount
        ) {
            participant1_amount = 0;
        }

        // case2: participant1_transferred_amount can be [0, real_participant1_transferred_amount)
        // This means participant1_amount > total_available_deposit.
        // We need to limit participant1_amount to total_available_deposit. It is fine if
        // participant1 gets all the available tokens if participant2 has not provided a
        // valid balance proof.
        participant1_amount = min(participant1_amount, total_deposit);
        // At this point `participant1_amount` is between [0,total_deposit], so this is safe.
        //变量复用是因为局部变量不能超过16个
        participant2_transferred_amount = total_deposit - participant1_amount;
        // participant1_amount is the amount of tokens that participant1 will receive
        // participant2_amount is the amount of tokens that participant2 will receive
        // Remove the channel data from storage
        delete channel.participants[participant1];
        delete channel.participants[participant2];
        delete channels[channel_identifier];
        // Do the actual token transfers
        if (participant1_amount > 0) {
            require(token.transfer(participant1, participant1_amount));
        }

        if (participant2_transferred_amount > 0) {
            require(token.transfer(participant2, participant2_transferred_amount));
        }

        emit ChannelSettled(
            channel_identifier,
            participant1_amount,
            participant2_transferred_amount
        );
    }

    /*
    任何人都可以调用,只能调用一次.
    */
    function cooperativeSettle(
        address participant1_address,
        uint256 participant1_balance,
        address participant2_address,
        uint256 participant2_balance,
        bytes participant1_signature,
        bytes participant2_signature //这里参数顺序和上面不一致,是因为不同的参数顺序会造成额外的 stack 占用,从而导致局部变量超过16个字
    )
    public
    {
        address participant;
        uint256 total_deposit;
        bytes32 channel_identifier;
        uint64 open_blocknumber;
        channel_identifier = getChannelIdentifier(participant1_address, participant2_address);
        Channel storage channel = channels[channel_identifier];
        // The channel must be open
        require(channel.state == 1);

        open_blocknumber = channel.open_block_number;
        participant = recoverAddressFromCooperativeSettleSignature(
            channel_identifier,
            participant1_address,
            participant1_balance,
            participant2_address,
            participant2_balance,
            open_blocknumber,
            participant1_signature
        );
        require(participant1_address == participant);
        participant = recoverAddressFromCooperativeSettleSignature(
            channel_identifier,
            participant1_address,
            participant1_balance,
            participant2_address,
            participant2_balance,
            open_blocknumber,
            participant2_signature
        );
        require(participant2_address == participant);

        Participant storage participant1_state = channel.participants[participant1_address];
        Participant storage participant2_state = channel.participants[participant2_address];


        total_deposit = participant1_state.deposit + participant2_state.deposit;

        // Remove channel data from storage before doing the token transfers
        delete channel.participants[participant1_address];
        delete channel.participants[participant2_address];
        delete channels[channel_identifier];
        // Do the token transfers
        if (participant1_balance > 0) {
            require(token.transfer(participant1_address, participant1_balance));
        }

        if (participant2_balance > 0) {
            require(token.transfer(participant2_address, participant2_balance));
        }


        // The sum of the provided balances must be equal to the total available deposit
        //一定要严防双方互相配合,侵占tokennetwork 资产的行为
        require(total_deposit == (participant1_balance + participant2_balance));
        require(total_deposit >= participant1_balance);
        require(total_deposit >= participant2_balance);
        emit ChannelCooperativeSettled(channel_identifier, participant1_balance, participant2_balance);
    }

    function getChannelIdentifier(address participant1, address participant2) view internal returns (bytes32){
        if (participant1 < participant2) {
            return keccak256(abi.encodePacked(participant1, participant2, address(this)));
        } else {
            return keccak256(abi.encodePacked(participant2, participant1, address(this)));
        }
    }

    function calceBalanceHash(uint256 transferred_amount, bytes32 locksroot) pure internal returns (bytes24){
        if (locksroot == 0 && transferred_amount == 0) {
            return 0;
        }
        return bytes24(keccak256(abi.encodePacked(locksroot, transferred_amount)));
    }

    function getChannelInfo(address participant1, address participant2)
    view
    external
    returns (bytes32, uint64, uint64, uint8,uint64)
    {

        bytes32 channel_identifier;
        channel_identifier = getChannelIdentifier(participant1, participant2);
        Channel storage channel = channels[channel_identifier];

        return (
        channel_identifier,
        channel.settle_block_number,
        channel.open_block_number,
        channel.state,
        channel.settle_timeout
        );
    }
    function getChannelInfoByChannelIdentifier( bytes32 channel_identifier )
    view
    external
    returns (bytes32, uint64, uint64, uint8,uint64)
    {
        Channel storage channel = channels[channel_identifier];

        return (
        channel_identifier,
        channel.settle_block_number,
        channel.open_block_number,
        channel.state,
        channel.settle_timeout
        );
    }
    function getChannelParticipantInfo(address participant, address partner)
    view
    external
    returns (uint256, bytes24, uint64)
    {

        bytes32 channel_identifier = getChannelIdentifier(participant, partner);
        Channel storage channel = channels[channel_identifier];
        Participant storage participant_state = channel.participants[participant];

        return (
        participant_state.deposit,
        participant_state.balance_hash,
        participant_state.nonce
        );
    }



    /*
     * Internal Functions
     */


    function recoverAddressFromBalanceProof(
        bytes32 channel_identifier,
        uint256 transferred_amount,
        bytes32 locksroot,
        uint64 nonce,
        uint64 open_blocknumber,
        bytes32 additional_hash,
        bytes signature
    )
    view
    internal
    returns (address signature_address)
    {
        bytes32 message_hash = keccak256(abi.encodePacked(
                transferred_amount,
                locksroot,
                nonce,
                additional_hash,
                channel_identifier,
                open_blocknumber,
            // address(this),
                chain_id
            ));

        signature_address = ECVerify.ecverify(message_hash, signature);
    }


    function recoverAddressFromBalanceProofUpdateMessage(
        bytes32 channel_identifier,
        uint256 transferred_amount,
        bytes32 locksroot,
        uint64 nonce,
        uint64 open_blocknumber,
        bytes32 additional_hash,
        bytes closing_signature,
        bytes non_closing_signature
    )
    view
    internal
    returns (address signature_address)
    {
        bytes32 message_hash = keccak256(abi.encodePacked(
                transferred_amount,
                locksroot,
                nonce,
                additional_hash,
                channel_identifier,
                open_blocknumber,
            //address(this),
                chain_id,
                closing_signature
            ));

        signature_address = ECVerify.ecverify(message_hash, non_closing_signature);
    }

    function recoverAddressFromCooperativeSettleSignature(
        bytes32 channel_identifier,
        address participant1,
        uint256 participant1_balance,
        address participant2,
        uint256 participant2_balance,
        uint64 open_blocknumber,
        bytes signature
    )
    view
    internal
    returns (address signature_address)
    {
        bytes32 message_hash = keccak256(abi.encodePacked(
                participant1,
                participant1_balance,
                participant2,
                participant2_balance,
                channel_identifier,
                open_blocknumber,
            //address(this),
                chain_id
            ));

        signature_address = ECVerify.ecverify(message_hash, signature);
    }

    function computeMerkleRoot(bytes32 lockhash, bytes merkle_proof)
    pure
    internal
    returns (bytes32)
    {
        require(merkle_proof.length % 32 == 0);

        uint256 i;
        bytes32 el;

        for (i = 32; i <= merkle_proof.length; i += 32) {
            assembly {
                el := mload(add(merkle_proof, i))
            }

            if (lockhash < el) {
                lockhash = keccak256(abi.encodePacked(lockhash, el));
            } else {
                lockhash = keccak256(abi.encodePacked(el, lockhash));
            }
        }

        return lockhash;
    }

    function recoverAddressFromUnlockProof(
        bytes32 channel_identifier,
        bytes32 lockhash,
        uint64 open_blocknumber,
        bytes32 additional_hash,
        bytes signature
    )
    view
    internal
    returns (address signature_address)
    {
        bytes32 message_hash = keccak256(abi.encodePacked(
                lockhash,
                channel_identifier,
                open_blocknumber,
            // address(this),
                chain_id,
                additional_hash
            ));

        signature_address = ECVerify.ecverify(message_hash, signature);
    }

    function min(uint256 a, uint256 b) pure internal returns (uint256)
    {
        return a > b ? b : a;
    }
}
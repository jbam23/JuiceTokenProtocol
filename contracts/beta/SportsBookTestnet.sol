//SPDX-License-Identifier: MIT
pragma solidity >0.4.13 <0.7.7;

import "../SafeMath6.sol";
import "../strings.sol";
import "../interfaces/IERC206.sol";
import "../interfaces/IWETH6.sol";
import "@chainlink/contracts/src/v0.6/ChainlinkClient.sol";
pragma experimental ABIEncoderV2;

/*

    Kovan Testnet Sports Book Contract for the Juice Token Protocol
    Rules for bets are scaled up by a factor of ten (i.e. a spread bet of +2.5 would be stored as 25)

*/

contract SportsBook is ChainlinkClient  {
    uint256 public STRAIGHT_ORACLE_PAYMENT = 1 * LINK;
    uint256 public PARLAY_ORACLE_PAYMENT = 1 * LINK;
    uint256 public SCORES_ORACLE_PAYMENT = 1 * LINK;
    uint256 public STATUS_ORACLE_PAYMENT = 1 * LINK;
    using strings for *;
    using SafeMath for uint256;
    
    event BetRequested(bytes32 betID,bytes16 betRef);
    event BetAccepted(bytes16 betRef,uint256 odds);
    event BetPayout(bytes16 betRef);
    event BetPush(bytes16 betRef);
    event BetRefunded(bytes16 betRef);
    event BetDeleted(bytes16 betRef);
    event ParlayAccepted(bytes16 betRef,bytes32 odds);
    event ScoreRecorded(uint256 index);
    
    struct MatchScores{
        string homeScore;
        string awayScore;
        uint256 recorded;
    }
    
    struct Bet{
        uint256 index;
        uint256 timestamp;

        uint256 selection;
        uint256 amount;

        uint256 odds;
        int256 rule;

        bytes16 betRef;

        address creator;
    }

    struct Parlay{
        uint256 amount;
        uint256 timestamp;

        bytes32 odds;
        
        string[] indexes;
        string[] selections;
        int[] rules;

        bytes16 betRef;

        address creator;
    }

    mapping(bytes16 => Parlay) public parlays;
    mapping(bytes16 => Bet) public bets;
    mapping(uint => MatchScores) public matchResults;
    mapping(uint256 => uint256) public matchCancellationTimestamp;
    mapping(uint256 => bool) public queriedIndexes;
    mapping(bytes32 => uint256) public queriedIDs;
    mapping(bytes32 => uint256) public queriedStatus;
    mapping(bytes32 => bytes16) public queriedBets;
    mapping(bytes32 => bytes16) public queriedParlays;
    mapping(address => bool) public wards;
    mapping(address => bytes16[]) public addressBets;
    mapping(uint256 => bool) public banned;

    modifier isWard(){
        require (wards[msg.sender], "Error: Wards only");
        _;
    }

    modifier isOracle(){
        require (msg.sender == oracle , "Error: Oracle only");
        _;
    }

    address oracle;
    address mesaj;
    address treasury;
    int256 MAX_BET;
    IERC20 dai;
    bool public isOperational = false;
    bool public freeFee = false;
    bool public noNewBets = false;
    IWETH weth;

    constructor (IERC20 _DAI, IWETH _WETH,  address _treasury) public payable{
        setPublicChainlinkToken();

        mesaj = msg.sender;
        wards[mesaj] = true;
        
        oracle = 0xF405B99ACa8578B9eb989ee2b69D518aaDb90c1F;        //CHANGE
        dai = _DAI;
        weth = _WETH;
        treasury = _treasury;
    }

    function bet(bytes16 _betRef, uint256 _index, uint256 _selection, uint256 _wagerAmt, int256 _rule ) public payable {
        require(isOperational, 'Sports Book not Operational');
        require(!noNewBets, 'Sports Book not accepting new wagers');
        require(address(bets[_betRef].creator) == address(0x0), 'Are you malicious or are you unlucky?');
        require(!banned[_index], "Sports Book not accepting wagers for specified Game ID");

        bytes32 _queryID = buildBet(_index, _selection, _rule, _wagerAmt);
        
        if(_queryID != 0x0){
            dai.transferFrom(msg.sender, treasury, _wagerAmt);
            Bet storage b = bets[_betRef];
            b.creator = msg.sender;
            b.index = _index;
            b.amount = _wagerAmt;
            b.selection = _selection;
            b.rule = _rule;
            b.timestamp = block.timestamp;
            b.betRef = _betRef;
            
            addressBets[b.creator].push(_betRef);
            queriedBets[_queryID] = _betRef;
            emit BetRequested(_queryID, _betRef);
        }
    }

    function betParlay( bytes16 _betRef,uint _wagerAmt, string memory _indexes, string memory _selections,  int[] memory _rules ) public payable{
        require(isOperational, 'Sports Book not Operational');
        require(!noNewBets, 'Sports Book not accepting new wagers');
        require(address(parlays[_betRef].creator) == address(0x0), 'Are you malicious or are you unlucky?');
     
        bytes32 _queryID = buildParlay( _indexes, _selections, _rules, _wagerAmt );

        if(_queryID != 0x0){
            dai.transferFrom(msg.sender, treasury, _wagerAmt);
            strings.slice memory k = _indexes.toSlice();
            strings.slice memory delim = ",".toSlice();
            string[] memory indexes = new string[](k.count(delim) + 1);

            require(indexes.length < 8, 'Parlay too large');

            for(uint i = 0; i < indexes.length; i++) {
                indexes[i] = k.split(delim).toString();
                if(banned[uint256(stringToBytes32(indexes[i]))]){
                    revert("Sports Book not accepting wagers for specified Game ID");
                }
            }
            
            strings.slice memory s =  _selections.toSlice();
            strings.slice memory delims = ",".toSlice();
            string[] memory selections = new string[](s.count(delims) + 1);
            for(uint i = 0; i < selections.length; i++) {
                selections[i] = s.split(delims).toString();
            }
                
            Parlay storage p = parlays[_betRef];
            p.creator = msg.sender;
            p.amount = _wagerAmt;
            p.indexes = indexes;
            p.selections = selections;
            p.rules = _rules;
            p.timestamp = block.timestamp;
            p.betRef = _betRef;
        
            queriedParlays[_queryID] = _betRef;
            addressBets[p.creator].push(_betRef);
            emit BetRequested(_queryID, _betRef);
        }
    }
    
    function resolveMatch( bytes16 _betRef ) public {
        require(isOperational, 'Sports Book not active');
        Bet memory b = bets[_betRef];
        require(_betRef != 0x0, "Invalid Bet Reference");
        require(b.timestamp>matchCancellationTimestamp[b.index], 'Match is invalid');
        require(matchResults[b.index].recorded + 604800 > block.timestamp, "Match Results only valid for 1 week");

        uint256 result = computeResult(b.index,b.selection,b.rule);
        //Win
        if(result == 1){
            uint256 amt = b.amount;
            uint256 odds = b.odds;
            address creator = b.creator;

            delete bets[_betRef];
            uint256 winAmt = amt.mul(odds).div(100);
            dai.transferFrom(treasury,creator,winAmt);
            emit BetPayout(_betRef);
        }
        //Push
        else if(result == 2){
            uint256 pushAmt = b.amount;
            address creator = b.creator;

            delete bets[_betRef];
            dai.transferFrom(treasury,creator,pushAmt);
            emit BetPush(_betRef);
        }
    }
    
    function resolveParlay( bytes16 _betRef ) public {
        require(isOperational, 'Sports Book not active');
        Parlay memory p = parlays[_betRef];
        require(_betRef != 0x0, "Invalid Bet Reference");
        
        strings.slice memory o = bytes32ToString(p.odds).toSlice();
        strings.slice memory delim = ",".toSlice();
        strings.slice[] memory os = new strings.slice[](o.count(delim) + 1);
        
        bool win = true;
        for(uint i = 0; i < os.length; i++){
            require(matchResults[bytesToUInt(stringToBytes32(p.indexes[i]))].recorded + 604800 > block.timestamp, "Match Results only valid for 1 week");
            uint256 ans = computeResult(bytesToUInt(stringToBytes32(p.indexes[i])),bytesToUInt(stringToBytes32(p.selections[i])), p.rules[i]);
            uint256 timestamp = matchCancellationTimestamp[bytesToUInt(stringToBytes32(p.indexes[i]))];
            if(ans == 0){
                win = false;
            }
            //Leg of parlay pushed or cancelled, set the odds to 100 effectively nullifying that leg of parlay
            else if(ans == 2 || p.timestamp<timestamp){
                os[i] = '100'.toSlice();
            }
            else{
                os[i] = o.split(delim);
            }
        }     

        if(win){
            uint256 odds = calculateParlayOdds(os);
            uint256 amt = p.amount;
            address creator = p.creator;

            delete parlays[_betRef];
            uint256 winAmt = amt.mul(odds).div(100);
            dai.transferFrom(treasury,creator,winAmt);
            emit BetPayout(_betRef);
        }
    }

    /* 
        Refund bet if match has a valid cancelation timestamp after the bet
        was placed or if 5 minutes have passed and the bet has not received valid odds
    */
    function refundBet( bytes16 _betRef) external {
        require(isOperational, 'Sports Book not active');
        Bet memory b = bets[_betRef];
        uint256 timestamp = matchCancellationTimestamp[b.index];
        uint256 current = block.timestamp;
        if(b.timestamp < timestamp || ((b.timestamp + 300) < current) && !(b.odds > 100)){
            uint256 amt = b.amount;
            address refundee = b.creator;
            delete bets[_betRef];
            dai.transferFrom(treasury,refundee,amt);
            emit BetRefunded(_betRef);
        }
    }

    /*
        Every leg of the parlay must have a valid
        match cancellation timestamp greater than
        the bet placement timestamp to refund bet
        or if 5 minutes have passed and the parlay
        has not received valid odds
    */
    function refundParlay( bytes16 _betRef) external {
        require(isOperational, 'Sports Book not active');
        Parlay memory p = parlays[_betRef];
        uint256 current = block.timestamp;

        if((p.timestamp + 300) < current && p.odds == bytes32(0)){
            uint256 amt = p.amount;
            address refundee = p.creator;
            delete parlays[_betRef];

            dai.transferFrom(treasury,refundee,amt);
            emit BetRefunded(_betRef);
        }
        else{
            for(uint i=0;i<p.indexes.length;i++){
                uint256 timestamp = matchCancellationTimestamp[stringToUint(p.indexes[i])];
                if(p.timestamp > timestamp){
                    revert("Parlay has valid legs");
                }
            }
            uint256 amt = p.amount;
            address refundee = p.creator;
            delete parlays[_betRef];
            dai.transferFrom(treasury,refundee,amt);
            emit BetRefunded(_betRef);
        }
    }


    /*
        Ward-Only Functions
    */

     // Only to be used to allow wards to delete faulty bets to protect sports book, 
    // returns wager amount to bet creator
    function deleteBet(bytes16 _betRef, bool _straight) public isWard(){
        if(_straight){
            Bet memory b = bets[_betRef];
            uint256 amt = b.amount;
            address creator = b.creator;
            delete bets[_betRef];
            dai.transferFrom(treasury,creator,amt);
        }else{
            Parlay memory p = parlays[_betRef];
            uint256 amt = p.amount;
            address creator = p.creator;
            delete parlays[_betRef];
            dai.transferFrom(treasury,creator,amt);
        }
        emit BetDeleted(_betRef);
    }

    function setSportsBookState(bool state) public isWard(){
        isOperational = state;
    }

    function setNoNewBets(bool state) public isWard(){
        noNewBets = state;
    }

    function setWard(address appointee) public isWard(){
        require(!wards[appointee], "Appointee is already ward.");
        wards[appointee] = true;
    }

    function abdicate(address shame) public isWard(){
        require(mesaj != shame, "Et tu, Brute?");
        wards[shame] = false;
    }

    function setFeeState(bool isFree) public isWard(){
        freeFee = isFree;
    }

    // Set Ban state for Game ID _subject
    function setBan(uint256 _subject, bool _isBanned) public isWard(){
        banned[_subject] = _isBanned;
    }

    function setStraightOraclePayment(uint256 amt) public isWard(){
        STRAIGHT_ORACLE_PAYMENT = amt;
    }
    
    function setParlayOraclePayment(uint256 amt) public isWard(){
        PARLAY_ORACLE_PAYMENT = amt;
    }
    
    function setScoresOraclePayment(uint256 amt) public isWard(){
        SCORES_ORACLE_PAYMENT = amt;
    }

    function setStatusOraclePayment(uint256 amt) public isWard(){
        STATUS_ORACLE_PAYMENT = amt;
    }

    function eraseMatchResult( uint256 _index ) public isWard(){
        delete matchResults[_index];
    }

    function setTreasury( address _treasury ) public isWard(){
        require(treasury == address(0x0), "Treasury Address Already Initialized");
        treasury = _treasury;
    }

    // Returns 1 for win, 2 for push
    function computeResult( uint256 _index, uint256 _selection, int256 _rule ) internal view returns(uint win){
        MatchScores memory m = matchResults[_index];
        
        uint256 home_score = bytesToUInt(stringToBytes32(m.homeScore));
        uint256 away_score = bytesToUInt(stringToBytes32(m.awayScore));
        uint selection = _selection;
        int rule = _rule;   //rule is scaled up by 10 to deal with half points

        if(selection == 0){
            if( int(home_score*10)+rule > int(away_score*10) ){
                win = 1;
            }
            else if( int(home_score*10)+rule == int(away_score*10) ){
                win = 2;
            }
        }
        else if(selection == 1){
            if( (int(away_score*10)+rule) > int(home_score*10)){
                win = 1;
            }
            else if( (int(away_score*10)+rule) == int(home_score*10) ){
                win = 2;
            }
        }
        else if (selection == 2 ){
            if(int(home_score*10 + away_score*10) > rule){
                win = 1;
            }
            else if (int(home_score*10 + away_score*10) == rule){
                win = 2;
            }
        }
        else if(selection == 3){
           if(rule > int(home_score*10 + away_score*10)){
                win = 1;
            }
            else if (rule == int(home_score*10 + away_score*10)){
                win = 2;
            }
        }
        else if(selection == 4 ){
              if((home_score > away_score)){
                win = 1;
            }
            else if (home_score == away_score){
                win = 2;
            }
        }
        else if (selection == 5 ){
            if(away_score > home_score){
                win = 1;
            }
            else if(away_score == home_score){
                win = 2;
            }
        }
    }

    /* 
        ChainLink Node Requesters:
        Final Score and Status Requesters are called publically, and odds
        requesters are called internally through bet and betParlay
    */
    function fetchFinalScore( uint256 _index ) public {
        require(!queriedIndexes[_index], "Index Already Queried");
        require(matchResults[_index].recorded == 0, "Index Already Recorded");
        Chainlink.Request memory req =  buildChainlinkRequest(stringToBytes32('01d5e3df39e3424791144e7dd3dbf58d'), address(this), this.fulfillScores.selector);
        req.add('type', 'score');
        req.addUint('index', _index);
        req.add('origin', 'ETH');
        bytes32 _queryID = sendChainlinkRequestTo(oracle, req, SCORES_ORACLE_PAYMENT);
        queriedIDs[_queryID] = _index;
        queriedIndexes[_index] = true;
    }

    function checkMatchStatus ( uint256 _index ) public {
        Chainlink.Request memory req = buildChainlinkRequest(stringToBytes32('eb5c834605004565b3daf7aa5f6d7460'), address(this), this.fulfillStatus.selector);
        req.add('type', 'status');
        req.addUint('index', _index);
        req.add('origin', 'ETH');
        bytes32 _queryID = sendChainlinkRequestTo(oracle, req, STATUS_ORACLE_PAYMENT);
        queriedStatus[_queryID] = _index;
    }

    function buildBet( uint256 _index, uint256 _selection, int256 _rule, uint256 _wagerAmt) internal returns (bytes32 _queryID){
        Chainlink.Request memory req =  buildChainlinkRequest(stringToBytes32('9c8e408a648f400c96147b62b591b31a'), address(this), this.fulfillBetOdds.selector);
        req.add('type', 'straight');
        req.addUint('index', _index);
        req.addUint('selection', _selection);
        req.addInt('rule', _rule);
        req.addUint('wagerAmt', (_wagerAmt/1000000000000000000));
        req.add('origin', 'ETH');
        _queryID = sendChainlinkRequestTo(oracle, req, STRAIGHT_ORACLE_PAYMENT);
    }
    
    function buildParlay(string memory _indexes, string memory _selections, int[] memory _rules, uint256 _wagerAmt) internal returns (bytes32 _queryID){
        string memory s;
        for(uint i = 0; i < _rules.length; i++){
            if(i!=0){
                s = s.toSlice().concat(','.toSlice());
            }
            s = s.toSlice().concat(intToString(_rules[i]).toSlice());
        }
        Chainlink.Request memory req = buildChainlinkRequest(stringToBytes32('ea2ba5b235cc4893bfc18935233333d6'), address(this), this.fulfillParlayOdds.selector);
        req.add('type', 'parlay');
        req.add('index', _indexes);
        req.add('selection', _selections);
        req.add('rule', s);
        req.addUint('wagerAmt', (_wagerAmt/1000000000000000000));
        req.add('origin', 'ETH');
        _queryID = sendChainlinkRequestTo(oracle, req, PARLAY_ORACLE_PAYMENT);
    }
    
    /* Oracle-Only Fulfillers  */
    function fulfillStatus(bytes32 _requestId, bool status) public isOracle() recordChainlinkFulfillment(_requestId){
        uint256 index = queriedIDs[_requestId];
        if( status ){
            matchCancellationTimestamp[index] = block.timestamp;
        }
        delete queriedIDs[_requestId];
    }

    function fulfillParlayOdds(bytes32 _requestId, bytes32 _odds) public isOracle() recordChainlinkFulfillment(_requestId){
        Parlay storage p = parlays[queriedParlays[_requestId]];
        p.odds = _odds;
        delete queriedParlays[_requestId];
        emit ParlayAccepted(p.betRef,p.odds);
    }
    
    function fulfillBetOdds(bytes32 _requestId, uint256 _odds) public isOracle() recordChainlinkFulfillment(_requestId){
        Bet storage b = bets[queriedBets[_requestId]];
        b.odds = _odds;
        delete queriedBets[_requestId];
        emit BetAccepted(b.betRef,_odds);
    }
    
    function fulfillScores(bytes32 _requestId, bytes32 score) public isOracle() recordChainlinkFulfillment(_requestId){
        require(score != 0x0, "Invalid Response");
        strings.slice memory s = bytes32ToString(score).toSlice();
        strings.slice memory part;
        MatchScores storage m = matchResults[queriedIDs[_requestId]];
        m.homeScore = s.split(",".toSlice(), part).toString();
        m.awayScore = s.split(",".toSlice(), part).toString();
        m.recorded = block.timestamp;
        queriedIndexes[queriedIDs[_requestId]] = false;
        emit ScoreRecorded(queriedIDs[_requestId]);
        delete queriedIDs[_requestId];
    }

    /* Utilities */
    function calculateParlayOdds(strings.slice[] memory o) internal view returns (uint256 odds){
        odds = 1;
        for(uint i=0;i < o.length; i++){
            if(i==0){
                odds = odds.mul(stringToUint(o[i].toString()));
            }
            else{
                odds = odds.mul(stringToUint(o[i].toString())).div(100);
            }
        }
    }

    function intToString(int i) internal pure returns (string memory){
        if (i == 0) return "0";
        bool negative = i < 0;
        uint j = uint(negative ? -i : i);
        uint l = j;
        uint len;
        while (j != 0){
            len++;
            j /= 10;
        }
        if (negative) ++len;
        bytes memory bstr = new bytes(len);
        uint k = len - 1;
        while (l != 0){
            bstr[k--] = byte(uint8(48 + l % 10));
            l /= 10;
        }
        if (negative) {
            bstr[0] = '-';
        }
        return string(bstr);
    }

    function stringToUint(string memory s) internal pure returns (uint result){
        bytes memory b = bytes(s);
        uint i;
        result = 0;
        for (i = 0; i < b.length; i++) {
            uint c = uint(uint8(b[i]));
            if (c >= 48 && c <= 57) {
                result = result * 10 + (c - 48);
            }
        }
    }
    
    function safeSub(uint256 a, uint256 b) internal pure returns (int256){
        int256 c = int256(a - b);
        require( c <= int256(a), "Sorry, subtraction is hard...");
        return c;
    }

    function safeMultiply(uint256 b, int256 a) internal pure returns (uint256){
        if (a == 0) {return 0;}
        uint256 c = uint256(a) * b;
        require(c / uint256(a) == b, "Sorry, multiplication is hard...");
        return c;
    }
    
    function safeDivide(uint256 a, int256 b) internal pure returns (uint256){
        require(b > 0, "Sorry, division is hard...");
        uint256 c = a / uint256(b);
        return c;
    }

    function safeAdd(uint256 a, uint256 b) internal pure returns (uint256){
        uint256 c = a + b;
        require(c >= a, "Sorry, addition is hard...");
        return c;
    }

    function bytesToUInt(bytes32 v) internal pure returns (uint ret){
        if (v == 0x0) {
            revert();
        }
        uint digit;
        for (uint i = 0; i < 32; i++) {
            digit = uint((uint(v) / (2 ** (8 * (31 - i)))) & 0xff);
            if (digit == 0) {
                break;
            }
            else if (digit < 48 || digit > 57) {
                revert();
            }
            ret *= 10;
            ret += (digit - 48);
        }
        return ret;
    }
      
    function stringToBytes32(string memory source) internal pure returns (bytes32 result){
        bytes memory tempEmptyStringTest = bytes(source);
        if (tempEmptyStringTest.length == 0) {
          return 0x0;
        }
    
        assembly {
          result := mload(add(source, 32))
        }
    }

    function bytes32ToString(bytes32 _bytes32) internal pure returns (string memory){
        uint8 i = 0;
        while(i < 32 && _bytes32[i] != 0) {
            i++;
        }
        bytes memory bytesArray = new bytes(i);
        for (i = 0; i < 32 && _bytes32[i] != 0; i++) {
            bytesArray[i] = _bytes32[i];
        }
        return string(bytesArray);
    }
}
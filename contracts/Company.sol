pragma solidity ^0.4.8;

import "./AbstractCompany.sol";

import "./accounting/AccountingLib.sol";
import "./bylaws/BylawsLib.sol";

import "./stocks/Stock.sol";
import "./stocks/IssueableStock.sol";
import "./stocks/GrantableStock.sol";

import "./votes/BinaryVoting.sol";
import "./votes/GenericBinaryVoting.sol";

import "./sales/AbstractStockSale.sol";

contract Company is AbstractCompany {
  using AccountingLib for AccountingLib.AccountingLedger;
  using BylawsLib for BylawsLib.Bylaws;

  AccountingLib.AccountingLedger accounting;
  BylawsLib.Bylaws bylaws;

  function Company() payable {
    votingIndex = 1; // Reverse index breaks when it is zero.
    saleIndex = 1;

    accounting.init(1 ether, 4 weeks, 1 wei); // Init with 1 ether budget and 1 moon period

    // Make contract deployer executive
    setStatus(msg.sender, uint8(AbstractCompany.EntityStatus.God));
  }

  /*
  function () payable {
    if (msg.value < 1) throw;
    registerIncome("donation");
  }
  */

  modifier checkBylaws {
    if (!bylaws.canPerformAction(msg.sig, msg.sender)) throw;
    _;
  }

  function sigPayload(uint nonce) constant public returns (bytes32) {
    return sha3(address(this), nonce);
  }

  modifier checkSignature(address sender, bytes32 r, bytes32 s, uint8 v, uint nonce) {
    bytes32 signingPayload = sigPayload(nonce);
    if (usedSignatures[signingPayload]) throw;
    if (sender != ecrecover(signingPayload, v, r, s)) throw;
    usedSignatures[signingPayload] = true;
    _;
  }

  function beginUntrustedPoll(address voting, uint64 closingTime, address sender, bytes32 r, bytes32 s, uint8 v, uint nonce) checkSignature(sender, r, s, v, nonce) {
    if (!bylaws.canPerformAction(BylawsLib.keyForFunctionSignature("beginPoll(address,uint64,bool,bool)"), sender)) throw;
    doBeginPoll(voting, closingTime, false, false); // TODO: Make vote on create and execute great again
  }


  function setSpecialBylaws() {
    addSpecialStatusBylaw("assignStock(uint8,address,uint256)", AbstractCompany.SpecialEntityStatus.StockSale);
    addSpecialStatusBylaw("removeStock(uint8,address,uint256)", AbstractCompany.SpecialEntityStatus.StockSale);
    addSpecialStatusBylaw("castVote(uint256,uint8,bool)", AbstractCompany.SpecialEntityStatus.Shareholder);
  }

  function getBylawType(string functionSignature) constant returns (uint8 bylawType, uint64 updated, address updatedBy) {
    BylawsLib.Bylaw memory b = bylaws.getBylaw(functionSignature);
    updated = b.updated;
    updatedBy = b.updatedBy;

    if (b.voting.enforced) bylawType = 0;
    if (b.status.enforced) bylawType = 1;
    if (b.specialStatus.enforced) bylawType = 2;
  }

  function getStatusBylaw(string functionSignature) constant returns (uint8) {
    BylawsLib.Bylaw memory b = bylaws.getBylaw(functionSignature);

    if (b.status.enforced) return b.status.neededStatus;
    if (b.specialStatus.enforced) return b.specialStatus.neededStatus;

    return uint8(250);
  }

  function getVotingBylaw(string functionSignature) constant returns (uint256 support, uint256 base, bool closingRelativeMajority, uint64 minimumVotingTime) {
    BylawsLib.VotingBylaw memory b = bylaws.getBylaw(functionSignature).voting;

    support = b.supportNeeded;
    base = b.supportBase;
    closingRelativeMajority = b.closingRelativeMajority;
    minimumVotingTime = b.minimumVotingTime;
  }

  function getVotingBylaw(bytes4 functionSignature) constant returns (uint256 support, uint256 base, bool closingRelativeMajority, uint64 minimumVotingTime) {
    BylawsLib.VotingBylaw memory b = bylaws.getBylaw(functionSignature).voting;

    support = b.supportNeeded;
    base = b.supportBase;
    closingRelativeMajority = b.closingRelativeMajority;
    minimumVotingTime = b.minimumVotingTime;
  }

  function addStatusBylaw(string functionSignature, AbstractCompany.EntityStatus statusNeeded) checkBylaws {
    BylawsLib.Bylaw memory bylaw = BylawsLib.init();
    bylaw.status.neededStatus = uint8(statusNeeded);
    bylaw.status.enforced = true;

    addBylaw(functionSignature, bylaw);
  }

  function addSpecialStatusBylaw(string functionSignature, AbstractCompany.SpecialEntityStatus statusNeeded) checkBylaws {
    BylawsLib.Bylaw memory bylaw = BylawsLib.init();
    bylaw.specialStatus.neededStatus = uint8(statusNeeded);
    bylaw.specialStatus.enforced = true;

    addBylaw(functionSignature, bylaw);
  }

  function addVotingBylaw(string functionSignature, uint256 support, uint256 base, bool closingRelativeMajority, uint64 minimumVotingTime, uint8 option) checkBylaws {
    BylawsLib.Bylaw memory bylaw = BylawsLib.init();

    bylaw.voting.supportNeeded = support;
    bylaw.voting.supportBase = base;
    bylaw.voting.closingRelativeMajority = closingRelativeMajority;
    bylaw.voting.minimumVotingTime = minimumVotingTime;
    bylaw.voting.approveOption = option;
    bylaw.voting.enforced = true;

    addBylaw(functionSignature, bylaw);
  }

  function addBylaw(string functionSignature, BylawsLib.Bylaw bylaw) private {
    bylaws.addBylaw(functionSignature, bylaw);

    BylawChanged(functionSignature);
  }

  // acl

  function setEntityStatusByStatus(address entity, uint8 status) public {
    if (entityStatus[msg.sender] < status) throw; // Cannot set higher status
    if (entity != msg.sender && entityStatus[entity] >= entityStatus[msg.sender]) throw; // Cannot change status of higher status

    // Exec can set and remove employees.
    // Someone with lesser or same status cannot change ones status
    setStatus(entity, status);
  }

  function setEntityStatus(address entity, uint8 status) checkBylaws public {
    setStatus(entity, status);
  }

  function setStatus(address entity, uint8 status) private {
    entityStatus[entity] = status;
    EntityNewStatus(entity, status);
  }

  // vote

  function countVotes(uint256 votingIndex, uint8 optionId) returns (uint256, uint256) {
    var (v, c, tv) = BylawsLib.countVotes(votingIndex, optionId);
    return (v, tv);
  }

  function setVotingExecuted(uint8 option) {
    uint256 votingIndex = reverseVotings[msg.sender];
    if (votingIndex == 0) throw;
    if (voteExecuted[votingIndex] > 0) throw;

    voteExecuted[votingIndex] = 10 + option; // avoid 0
    for (uint8 i = 0; i < stockIndex; i++) {
      Stock(stocks[i]).closePoll(votingIndex);
    }

    VoteExecuted(votingIndex, msg.sender, option);
  }

  function beginPoll(address voting, uint64 closes, bool voteOnCreate, bool executesIfDecided) public checkBylaws {
    return doBeginPoll(voting, closes, voteOnCreate, executesIfDecided);
  }

  function doBeginPoll(address voting, uint64 closes, bool voteOnCreate, bool executesIfDecided) private {
    Voting v = Voting(voting);
    for (uint8 i = 0; i < stockIndex; i++) {
      Stock(stocks[i]).beginPoll(votingIndex, closes);
    }
    votings[votingIndex] = voting;
    reverseVotings[voting] = votingIndex;

    if (voteOnCreate) castVote(votingIndex, uint8(BinaryVoting.VotingOption.Favor), executesIfDecided);

    votingIndex += 1;
  }

  function castVote(uint256 voteId, uint8 option, bool executesIfDecided) public checkBylaws {
    if (voteExecuted[voteId] > 0) throw; // cannot vote on executed polls

    for (uint8 i = 0; i < stockIndex; i++) {
      Stock stock = Stock(stocks[i]);
      if (stock.isShareholder(msg.sender)) {
        stock.castVoteFromCompany(msg.sender, voteId, option);
      }
    }

    if (executesIfDecided) {
      address votingAddress = votings[voteId];
      BinaryVoting voting = BinaryVoting(votingAddress);
      if (bylaws.canPerformAction(voting.mainSignature(), votingAddress)) {
        voting.executeOnAction(uint8(BinaryVoting.VotingOption.Favor), this);
      }
    }
  }

  // stock
  function isShareholder(address holder) constant public returns (bool) {
    for (uint8 i = 0; i < stockIndex; i++) {
      if (Stock(stocks[i]).isShareholder(holder)) {
        return true;
      }
    }
    return false;
  }

  function addStock(address newStock, uint256 issue) checkBylaws public {
    if (Stock(newStock).company() != address(this)) throw;

    IssueableStock(newStock).issueStock(issue);

    stocks[stockIndex] = newStock;
    stockIndex += 1;

    IssuedStock(newStock, stockIndex - 1, issue);
  }

  function issueStock(uint8 _stock, uint256 _amount) checkBylaws public {
    IssueableStock(stocks[_stock]).issueStock(_amount);
    IssuedStock(stocks[_stock], _stock, _amount);
  }

  function grantVestedStock(uint8 _stock, uint256 _amount, address _recipient, uint64 _start, uint64 _cliff, uint64 _vesting) checkBylaws public {
    issueStock(_stock, _amount);
    GrantableStock(stocks[_stock]).grantVestedStock(_recipient, _amount, _start, _cliff, _vesting);
  }

  function grantStock(uint8 _stock, uint256 _amount, address _recipient) checkBylaws public {
    GrantableStock(stocks[_stock]).grantStock(_recipient, _amount);
  }

  // stock sales

  function beginSale(address saleAddress) checkBylaws public {

    AbstractStockSale sale = AbstractStockSale(saleAddress);
    if (sale.companyAddress() != address(this)) throw;

    sales[saleIndex] = saleAddress;
    reverseSales[saleAddress] = saleIndex;
    saleIndex += 1;

    NewStockSale(saleAddress, saleIndex - 1, sale.stockId());
  }

  function transferSaleFunds(uint256 _sale) checkBylaws public {
    AbstractStockSale(sales[_sale]).transferFunds();
  }

  function isStockSale(address entity) constant public returns (bool) {
    return reverseSales[entity] > 0;
  }

  function assignStock(uint8 stockId, address holder, uint256 units) checkBylaws {
    IssueableStock(stocks[stockId]).issueStock(units);
    GrantableStock(stocks[stockId]).grantStock(holder, units);
  }

  function removeStock(uint8 stockId, address holder, uint256 units) checkBylaws {
    IssueableStock(stocks[stockId]).destroyStock(holder, units);
  }

  // accounting
  function getAccountingPeriodRemainingBudget() constant returns (uint256) {
    var (budget,) = accounting.getAccountingPeriodState(accounting.getCurrentPeriod());
    return budget;
  }

  function getAccountingPeriodCloses() constant returns (uint64) {
    var (,closes) = accounting.getAccountingPeriodState(accounting.getCurrentPeriod());
    return closes;
  }

  function getPeriodInfo(uint periodIndex) constant returns (uint lastTransaction, uint64 started, uint64 ended, uint256 revenue, uint256 expenses, uint256 dividends) {
    AccountingLib.AccountingPeriod p = accounting.periods[periodIndex];
    lastTransaction = p.transactions.length - 1;
    started = p.startTimestamp;
    ended = p.endTimestamp > 0 ? p.endTimestamp : p.startTimestamp + p.periodDuration;
    expenses = p.expenses;
    revenue = p.revenue;
    dividends = p.dividends;
  }

  function getRecurringTransactionInfo(uint transactionIndex) constant returns (uint64 period, uint64 lastTransactionDate, address to, address approvedBy, uint256 amount, string concept) {
    AccountingLib.RecurringTransaction recurring = accounting.recurringTransactions[transactionIndex];
    AccountingLib.Transaction t = recurring.transaction;
    period = recurring.period;
    to = t.to;
    amount = t.amount;
    approvedBy = t.approvedBy;
    concept = t.concept;
  }

  function getTransactionInfo(uint periodIndex, uint transactionIndex) constant returns (bool expense, address from, address to, address approvedBy, uint256 amount, string concept, uint64 timestamp) {
    AccountingLib.Transaction t = accounting.periods[periodIndex].transactions[transactionIndex];
    expense = t.direction == AccountingLib.TransactionDirection.Outgoing;
    from = t.from;
    to = t.to;
    amount = t.amount;
    approvedBy = t.approvedBy;
    timestamp = t.timestamp;
    concept = t.concept;
  }

  function setAccountingSettings(uint256 budget, uint64 periodDuration, uint256 dividendThreshold) checkBylaws public {
    accounting.setAccountingSettings(budget, periodDuration, dividendThreshold);
  }

  function addTreasure(string concept) payable public returns (bool) {
    accounting.addTreasure(concept);
    return true;
  }

  /*
  function registerIncome(string concept) payable public returns (bool) {
    accounting.registerIncome(concept);
    return true;
  }
  */

  function splitIntoDividends() payable {
    /*
    TODO: Removed for gas limitations
    uint256 totalDividendBase;
    for (uint8 i = 0; i < stockIndex; i++) {
      Stock st = Stock(stocks[i]);
      totalDividendBase += st.totalSupply() * st.dividendsPerShare();
    }

    for (uint8 j = 0; j < stockIndex; j++) {
      Stock s = Stock(stocks[j]);
      uint256 stockShare = msg.value * (s.totalSupply() * s.dividendsPerShare()) / totalDividendBase;
      s.splitDividends.value(stockShare)();
    }
    */
  }

  function issueReward(address to, uint256 amount, string concept) checkBylaws {
    accounting.sendFunds(amount, concept, to);
  }

  function createRecurringReward(address to, uint256 amount, uint64 period, string concept) checkBylaws {
    accounting.sendRecurringFunds(amount, concept, to, period, true);
  }

  function removeRecurringReward(uint index) checkBylaws {
    accounting.removeRecurringTransaction(index);
  }
}

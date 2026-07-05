{=============================================================================
  QFF Monthly Rebalance Strategy -- PowerLanguage impl, per Functional Spec v1.0.
  Platform: KWAY MultiCharts (Pro).  Symbol: QFF mini-TSMC future, PtValue=100.
  Comment refs (Sec.1.3, App. C, ...) cite Functional Spec v1.0; top-level Sections 3/6/7/8/9/10.

  Logic (long-only lot-size rebalance):
   STEP1 (Sec.1.1) initial entry, flat start, formula-sized + margin cap.
   STEP2 (Sec.1.3-1.5) rebalance trigger, priority Rule3 > Rule1 > Rule2, one per bar.
   STEP3 (Sec.1.6) rebalance = Sell All then re-enter Buy on the NEXT bar; on daily K that = next trading day (flat 1 day, known cost).
   Margin monitor (Sec.4.1): equity <= maint-margin total -> ALERT. Margin ratios & disposition unreadable -> kept as MANUAL inputs.

  Roll-over offset (why NOT same-day, Sec.1.2): broker rolls ON settlement day intraday (UI ~13:20); daily K computes once at close
   and can't see that intraday roll, so same-day roll/rebalance order is unknowable. Rebalancing the NEXT trading day sidesteps
   this and never touches the expiring near month -> always acts on the already-rolled next month.

  Platform-side manual setup (NOT code):
   - Data = QFF1 continuous (auto-roll); broker order machine rolls month on settlement day. Strategy never switches month. (Sec.1.2/Sec.7)
   - Initial capital in Strategy Properties > Properties > Initial Capital; read via reserved InitialCapital (no input). (Sec.1.1/Sec.2.1)
   - Rule2 & stress test need IOG + Bar Magnifier else daily bar misses intrabar triggers. (App. A)
   - CSV folder (C:\QFF\) must pre-exist with write access; FileAppend won't create folders; else use Documents\QFF\ etc. (Sec.4.2)

  AvgEntryPrice / CurrentContracts = MC strategy INTERNAL ledger (own fills), NOT a broker-account query (TW builds can't read
   account inventory). Backtest: always consistent. Live: an ESTIMATE -> needs periodic MANUAL reconciliation. (App. C)

  CSV: 13 cols, no header, append; REBAL/ALERT/SNAP share one schema:
   tag,date,time,subtype,exposure_ratio,init_margin_ratio,maint_margin_ratio,contracts_after,price,entry_price,current_capital,baseline_capital,cum_realized_pnl
   subtype = INIT / UP / DOWN / FLAT / EXTRA / FORCE / MARGIN / DAILY
=============================================================================}

Inputs:
    ExposureRatio(2.0),                { Exposure multiple, 1.0-2.0; manual 1.5 on disposition (Rule 3). Sec.2.1/Sec.1.5 }
    RebalanceThreshold(0.03),          { Rule 1 monthly threshold (settlement+1 day), 0.01-0.10. Sec.2.1/Sec.1.3 }
    ExtraRebalanceThreshold(0.05),     { Rule 2 extra threshold (equity deviation), 0.03-0.15. Sec.2.1/Sec.1.4 }
    ForceRebalance(False),             { Rule 3 fire-once T/F; latch auto-clears after firing; must be reset to False
                                         manually to fire again (strategy can't rewrite its own input). Sec.1.5 }
    BacktestMode(True),                { T=backtest (writes qff_log_bt.csv, no notify); F=live (qff_log.csv, notify).
                                         Holiday roll-forward built into both modes. Sec.2.1/Sec.4.2 }
    LogDailySnapshot(True),            { T/F; T=write one daily SNAP equity snapshot (full analysis). Sec.2.1/Sec.4.2 }
    ActualMarginRatio(0.135),          { Initial-margin ratio, 0.135-0.27; normal 13.5%, manual up to 20.25%/27%
                                         on ex-div/disposition. Sec.2.2 }
    MaintMarginRatio(0.1035);          { Maintenance-margin ratio (alert), 0.1035-0.2025; normal 10.35%,
                                         manual sync up on disposition. Sec.2.2 }

Variables:
    PtValue(100),                      { Point value=100 (Sec.3, fixed const). Name avoids reserved PointValue/BigPointValue (Sec.2.1). }
    InitDone(False),
    InitLogged(False),
    BaselineCapital(0),                { Rebalance baseline equity; reset on Rule 1/2/3. Sec.5 }
    CumulativePnL(0),                  { Cumulative realized P&L. Sec.5 }
    CurrentCapital(0),                 { Current equity incl. floating. Sec.1.3 }
    NumContracts(0),
    TargetContracts(0),                { STEP2 target lots; reused in STEP3 (1-bar lag). Sec.8 }
    NewContracts(0),
    MaxByMargin(0),                    { Margin-capped lot ceiling (distinct from exposure-formula lots). Sec.1.1 }
    InitMarginPerLot(0),
    MaintMarginPerLot(0),
    MaintMarginTotal(0),
    InitMarginNow(0),
    CapAfter(0),
    LastEntryPrice(0),                 { Pre-close snapshot of AvgEntryPrice, for STEP3 realized-P&L fix. Sec.1.3/Sec.5 }
    LastSellContracts(0),              { Pre-close lot snapshot, for P&L fix. Sec.5 }
    NeedRebuy(False),
    Rebalanced(False),
    DoSell(False),
    IntraBarPersist AlertOnce(False),  { Must persist under IOG backtest, else multi-tick recompute on one daily K resets it
                                         and double-writes ALERT. App. A }
    IntraBarPersist LogCleaned(False), { Guard so backtest log is cleared once per run, not on every IOG
                                         tick of bar 1 (else a same-bar write could be wiped). App. A }
    ForceLatch(False),
    LastRebalanceDate(0),
    LastRule1Month(0),
    LastSettleMonth(0),
    SettleDate(0),
    LastSnapDate(0),
    MonthKey(0),
    ii(0),
    FirstOfMonth(0),                   { Backtest 3rd-Wed calendar calc. App. B }
    DOW1(0),
    FirstWedDay(0),
    ThirdWedDay(0),
    RebalDueThisMonth(False),
    PendingSubtype(""),
    LogFile("");

Arrays:
    SettleDates[72](0);                { [LIVE only, BacktestMode=False] actual settlement-day list (YYYMMDD,
                                         Date=(year-1900)*10000+MM*100+DD, e.g. 2026-06-17 -> 1260617).
                                         Source: broker roll module .reg RollOverDate. Maintained yearly.
                                         Convention: fill in .reg RollOverDate order, SettleDates[N]=.reg row N (eases yearly
                                         check); program matches by full-array scan, so order is for upkeep only.
                                         Backtest (=True) uses calendar 3rd-Wed instead, ignores this list. Sec.1.2/Sec.7.2/App. B }

{ ---- One-time: pick CSV file by mode + load this year's settlement list. Sec.4.2/Sec.1.2 ---- }
if CurrentBar = 1 then begin
    if BacktestMode then
        LogFile = "C:\QFF\qff_log_bt.csv"
    else
        LogFile = "C:\QFF\qff_log.csv";
    { Auto-clean old log ONLY in backtest, so each re-run writes a fresh file (no manual delete/move).
      CRITICAL: gated on BacktestMode. In LIVE, CurrentBar=1 fires on every ReCalculate
      (param change / pause-restart / chart reopen); an ungated FileDelete would WIPE the accumulating
      live qff_log.csv (the cross-day audit trail). Live must NEVER delete. Sec.4.2/App.C }
    if BacktestMode and LogCleaned = False then begin
        FileDelete(LogFile);
        LogCleaned = True;
    end;
    { [LIVE] settlement days (YYYMMDD) from broker .reg RollOverDate; maintained yearly. Order = .reg order, SettleDates[N]=row N.
      [1]=2025/12/17 cross-year start (rolls into 2026/01). [3]=02/23 Lunar-NY roll-forward (not nominal 3rd-Wed 18th).
      Backtest ignores this list (uses 3rd-Wed), so no multi-year fill needed here. App. B }
    SettleDates[1]  = 1251217;  { .reg#1  2025/12/17 -> into 2026/01 (cross-year start) }
    SettleDates[2]  = 1260121;  { .reg#2  2026/01/21 -> into 2026/02 }
    SettleDates[3]  = 1260223;  { .reg#3  2026/02/23 -> into 2026/03 (Lunar-NY roll-forward) }
    SettleDates[4]  = 1260318;  { .reg#4  2026/03/18 -> into 2026/04 }
    SettleDates[5]  = 1260415;  { .reg#5  2026/04/15 -> into 2026/05 }
    SettleDates[6]  = 1260520;  { .reg#6  2026/05/20 -> into 2026/06 }
    SettleDates[7]  = 1260617;  { .reg#7  2026/06/17 -> into 2026/07 }
    SettleDates[8]  = 1260715;  { .reg#8  2026/07/15 -> into 2026/08 }
    SettleDates[9]  = 1260819;  { .reg#9  2026/08/19 -> into 2026/09 }
    SettleDates[10] = 1260916;  { .reg#10 2026/09/16 -> into 2026/10 }
    SettleDates[11] = 1261021;  { .reg#11 2026/10/21 -> into 2026/11 }
    SettleDates[12] = 1261118;  { .reg#12 2026/11/18 -> into 2026/12 }
    SettleDates[13] = 1261216;  { .reg#13 2026/12/16 -> into 2027/01 }
    { Capital read via reserved InitialCapital (= Strategy Properties > Properties > Initial Capital; Capital build: Properties
      page, not Backtesting). <=0 => warn early; verify via 1st CSV baseline_capital. Sec.1.1/Sec.2.1 }
    if InitialCapital <= 0 then
        Print("WARNING: InitialCapital<=0 - set capital in Strategy Properties > Properties > Initial Capital");
end;

{ ---- Per-bar shared calc ---- }
{ If this build lacks Floor, use IntPortion (all values positive here, same result). }
InitMarginPerLot  = Floor(Close * PtValue * ActualMarginRatio);   { Initial margin/lot. Sec.2.2/Sec.3 }
MaintMarginPerLot = Floor(Close * PtValue * MaintMarginRatio);    { Maintenance margin/lot. Sec.2.2/Sec.3 }

{ Current equity incl. floating P&L (baseline = account equity, not TSMC price). Sec.1.3/Sec.4.1 }
if MarketPosition <> 0 then
    CurrentCapital = InitialCapital + CumulativePnL
                     + (Close - AvgEntryPrice) * CurrentContracts * PtValue
else
    CurrentCapital = InitialCapital + CumulativePnL;

{ ---- Settlement-day detect: live reads hard-coded list, backtest uses calendar 3rd-Wed. Sec.1.2/Sec.7.2 ----
  Why settlement+1: broker rolls ON settlement day intraday (UI ~13:20); daily K computes once at close and can't see that
  intraday roll, so same-day order is unknowable. Rebalancing the NEXT trading day sidesteps this and avoids the expiring
  near month. App. B for SettleDate definition. }
MonthKey = Year(Date) * 100 + Month(Date);

if BacktestMode then begin
    { Backtest: calendar 3rd Wed; if holiday, first bar with DayOfMonth >= 3rd-Wed auto-hits real roll-forward. App. B }
    FirstOfMonth = Date - DayOfMonth(Date) + 1;
    DOW1 = DayOfWeek(FirstOfMonth);        { 0=Sun ... 3=Wed ... 6=Sat }
    FirstWedDay = 1 + (3 - DOW1);
    if FirstWedDay < 1 then FirstWedDay = FirstWedDay + 7;
    ThirdWedDay = FirstWedDay + 14;        { calendar 3rd Wed (15-21) }
    if MonthKey <> LastSettleMonth and DayOfMonth(Date) >= ThirdWedDay then begin
        SettleDate      = Date;
        LastSettleMonth = MonthKey;
    end;
end
else begin
    { Live: today = a date in the hard-coded list -> record as this month's SettleDate. }
    for ii = 1 to 72 begin
        if SettleDates[ii] > 0 and Date = SettleDates[ii] then begin
            SettleDate      = Date;
            LastSettleMonth = MonthKey;
        end;
    end;
end;

{ This month's rebalance day = settlement found, now past it (settlement+1 onward), Rule 1 not yet done this month.
  Date > SettleDate also covers a holiday right after settlement. Sec.1.2/Sec.7.2 }
RebalDueThisMonth = (LastSettleMonth = MonthKey) and (Date > SettleDate)
                    and (MonthKey <> LastRule1Month);

{=============================================================================
  STEP 1: Initial entry (formula sizing, flat start). Sec.1.1
=============================================================================}
if InitDone = False then begin
    if Close > 0 and PtValue > 0 and InitialCapital > 0 then begin
        NumContracts = Floor(InitialCapital * ExposureRatio / (Close * PtValue));
        if InitMarginPerLot > 0 then begin
            MaxByMargin = Floor(InitialCapital / InitMarginPerLot);   { margin lot ceiling }
            if NumContracts > MaxByMargin then NumContracts = MaxByMargin;
        end;
        if NumContracts >= 1 then begin   { lots<1 or Close<=0 -> no entry. Sec.1.1/Sec.6 }
            Buy NumContracts Contracts Next Bar at Market;
            BaselineCapital = InitialCapital;
            CumulativePnL   = 0;
            InitDone        = True;
        end;
    end;
end;

{ Write one INIT row after initial fill. Sec.4.3 }
if InitDone and InitLogged = False and MarketPosition <> 0 then begin
    FileAppend(LogFile,
        "REBAL," + NumToStr(Date,0) + "," + NumToStr(Time,0) + ",INIT," +
        NumToStr(ExposureRatio,2) + "," + NumToStr(ActualMarginRatio,4) + "," + NumToStr(MaintMarginRatio,4) + "," +
        NumToStr(CurrentContracts,0) + "," + NumToStr(Open,2) + "," + NumToStr(AvgEntryPrice,2) + "," +
        NumToStr(CurrentCapital,0) + "," + NumToStr(BaselineCapital,0) + "," + NumToStr(CumulativePnL,0) + NewLine);
    InitLogged = True;
end;

{=============================================================================
  STEP 2: Rebalance trigger - priority Rule3 (now) > Rule1 (monthly) > Rule2 (extra). Sec.1.3-1.5
  Shared preconditions: in position, no pending rebuild (NeedRebuy=False), not yet acted today.
=============================================================================}
DoSell = False;

{ ---- Rule 3: ForceRebalance fire-once (Sec.1.5); latch auto-clears after one fire ---- }
if ForceRebalance and ForceLatch = False and MarketPosition <> 0 and NeedRebuy = False then begin
    DoSell = True;
    PendingSubtype = "FORCE";
    ForceLatch = True;
end;
if ForceRebalance = False then ForceLatch = False;   { input reset to False -> clear latch, can fire again }

{ ---- Rule 1: monthly (settlement+1 trading day), threshold RebalanceThreshold. Sec.1.3 ---- }
if DoSell = False and RebalDueThisMonth and MarketPosition <> 0
   and NeedRebuy = False and Date <> LastRebalanceDate then begin
    LastRule1Month = MonthKey;
    if CurrentCapital >= BaselineCapital * (1 + RebalanceThreshold) then begin
        DoSell = True; PendingSubtype = "UP";        { up-rebalance (add) }
    end
    else if CurrentCapital <= BaselineCapital * (1 - RebalanceThreshold) then begin
        DoSell = True; PendingSubtype = "DOWN";      { down-rebalance (trim), min 1 lot }
    end
    else begin
        { In-band: no change; write FLAT to mark month checked. Sec.1.3/Sec.4.3 }
        FileAppend(LogFile,
            "REBAL," + NumToStr(Date,0) + "," + NumToStr(Time,0) + ",FLAT," +
            NumToStr(ExposureRatio,2) + "," + NumToStr(ActualMarginRatio,4) + "," + NumToStr(MaintMarginRatio,4) + "," +
            NumToStr(CurrentContracts,0) + "," + NumToStr(Close,2) + "," + NumToStr(AvgEntryPrice,2) + "," +
            NumToStr(CurrentCapital,0) + "," + NumToStr(BaselineCapital,0) + "," + NumToStr(CumulativePnL,0) + NewLine);
        LastRebalanceDate = Date;
    end;
end;

{ ---- Rule 2: extra rebalance on equity deviation, threshold ExtraRebalanceThreshold. Sec.1.4
       Paused ON settlement day (uses actual SettleDate, holiday-adjusted); broker handles roll, resumes next day.
       Not-yet-this-period = Date<>LastRebalanceDate; same-period dedupe vs Rule 1 via baseline reset (Sec.6). ---- }
if DoSell = False and MarketPosition <> 0 and NeedRebuy = False
   and Date <> LastRebalanceDate and BaselineCapital > 0
   and Date <> SettleDate then begin
    if AbsValue(CurrentCapital - BaselineCapital) / BaselineCapital >= ExtraRebalanceThreshold then begin
        DoSell = True; PendingSubtype = "EXTRA";
    end;
end;

{ ---- Shared close-out: snapshot avg price/lots before close + compute target lots. Sec.1.3/Sec.1.7/Sec.8 ---- }
if DoSell then begin
    LastEntryPrice    = AvgEntryPrice;          { snapshot for STEP3 P&L fix (AvgEntryPrice zeroes after close) }
    LastSellContracts = CurrentContracts;
    { Sec.1.3: target lots at trigger (signal-bar Close, equity incl. floating), then margin cap.
      Reused in STEP3 (Sec.8: STEP3 uses STEP2 value, 1-bar lag). }
    TargetContracts = Floor(CurrentCapital * ExposureRatio / (Close * PtValue));
    if InitMarginPerLot > 0 then begin
        MaxByMargin = Floor(CurrentCapital / InitMarginPerLot);   { margin lot ceiling }
        if TargetContracts > MaxByMargin then TargetContracts = MaxByMargin;
    end;
    if TargetContracts < 1 then TargetContracts = 1;   { trim floor 1 lot }
    Sell ("Rebal") All Contracts Next Bar at Market;
    NeedRebuy         = True;
    Rebalanced        = True;
    LastRebalanceDate = Date;
end;

{=============================================================================
  STEP 3: Next-bar rebuild (Sec.1.6) - close-all then re-enter on the next bar.
=============================================================================}
if NeedRebuy and MarketPosition = 0 then begin
    { Close-price fix: this bar Open = Sell All fill price; settle realized P&L vs LastEntryPrice.
      P&L settles ONCE here = (sell-day Open - frozen old avg) * old lots * PtValue; trigger-day Close is decision-only,
      buy-day Open is new cost only. Worked example: App. H. }
    CumulativePnL = CumulativePnL + (Open - LastEntryPrice) * LastSellContracts * PtValue;
    CapAfter      = InitialCapital + CumulativePnL;
    { Sync CurrentCapital to the freshly-realized equity so the later SNAP row on this same
      bar writes the up-to-date value (position is flat here -> no floating term). Sec.4.3 }
    CurrentCapital = CapAfter;

    { Sec.1.6/Sec.8: reuse STEP2 target lots; only re-verify margin cap with today's latest InitialMargin.
      If reused lots > today's MaxByMargin -> reduce to cap, min 1, write WARNING (Sec.6/App. H); else keep, no re-size. }
    NewContracts = TargetContracts;
    if Open > 0 and PtValue > 0 then begin
        InitMarginNow = Floor(Open * PtValue * ActualMarginRatio);
        if InitMarginNow > 0 then begin
            MaxByMargin = Floor(CapAfter / InitMarginNow);   { margin lot ceiling }
            if NewContracts > MaxByMargin then begin
                Print("WARNING STEP3 margin-cap reduce ", NumToStr(Date,0), "  ",
                      NumToStr(NewContracts,0), " -> ", NumToStr(MaxByMargin,0));
                NewContracts = MaxByMargin;
            end;
        end;
    end;
    if NewContracts < 1 then NewContracts = 1;   { trim floor 1 lot. Sec.6 }

    Buy NewContracts Contracts Next Bar at Market;

    if Rebalanced then BaselineCapital = CapAfter;   { baseline update. Sec.1.6 }

    { Write REBAL (entry_price = LastEntryPrice = avg of the closed-out position). Sec.4.3 }
    FileAppend(LogFile,
        "REBAL," + NumToStr(Date,0) + "," + NumToStr(Time,0) + "," + PendingSubtype + "," +
        NumToStr(ExposureRatio,2) + "," + NumToStr(ActualMarginRatio,4) + "," + NumToStr(MaintMarginRatio,4) + "," +
        NumToStr(NewContracts,0) + "," + NumToStr(Open,2) + "," + NumToStr(LastEntryPrice,2) + "," +
        NumToStr(CapAfter,0) + "," + NumToStr(BaselineCapital,0) + "," + NumToStr(CumulativePnL,0) + NewLine);

    NeedRebuy  = False;
    Rebalanced = False;
end;

{=============================================================================
  Margin monitor + ALERT (Sec.4.1) - each bar while in position.
  Alert only when equity touches the maintenance-margin line; AlertOnce dedupes, resets after recovery.
  AlertOnce is IntraBarPersist: under IOG backtest one daily K computes many times (O/H/L/C); without persist the flag
  resets each compute and double-writes ALERT. Semantics kept: set True on breach, False on recovery (so "breach -> recover
  -> breach" same day alerts again). Live: IOG off, one compute/day, persist has no visible effect; live ALERT = close-only
  daily, one per wave; real limit is it can't stop an intraday crash. App. A / Sec.4.1 / Sec.1.4
=============================================================================}
if MarketPosition <> 0 then begin
    MaintMarginTotal = CurrentContracts * MaintMarginPerLot;
    if CurrentCapital <= MaintMarginTotal then begin
        if AlertOnce = False then begin
            FileAppend(LogFile,
                "ALERT," + NumToStr(Date,0) + "," + NumToStr(Time,0) + ",MARGIN," +
                NumToStr(ExposureRatio,2) + "," + NumToStr(ActualMarginRatio,4) + "," + NumToStr(MaintMarginRatio,4) + "," +
                NumToStr(CurrentContracts,0) + "," + NumToStr(Close,2) + "," + NumToStr(AvgEntryPrice,2) + "," +
                NumToStr(CurrentCapital,0) + "," + NumToStr(BaselineCapital,0) + "," + NumToStr(CumulativePnL,0) + NewLine);
            AlertOnce = True;
        end;
    end
    else
        AlertOnce = False;
end;

{=============================================================================
  SNAP daily equity snapshot (Sec.4.2) - one row on each day's first bar.
  (Daily bar = one/day; minute/Bar Magnifier = that day's first bar. For a fixed time, gate on Time.)
=============================================================================}
if LogDailySnapshot and Date <> LastSnapDate then begin
    FileAppend(LogFile,
        "SNAP," + NumToStr(Date,0) + "," + NumToStr(Time,0) + ",DAILY," +
        NumToStr(ExposureRatio,2) + "," + NumToStr(ActualMarginRatio,4) + "," + NumToStr(MaintMarginRatio,4) + "," +
        NumToStr(CurrentContracts,0) + "," + NumToStr(Close,2) + "," + NumToStr(AvgEntryPrice,2) + "," +
        NumToStr(CurrentCapital,0) + "," + NumToStr(BaselineCapital,0) + "," + NumToStr(CumulativePnL,0) + NewLine);
    LastSnapDate = Date;
end;
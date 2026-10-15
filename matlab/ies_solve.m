function res = ies_solve(p, mode, solver)
% IES_SOLVE  第 4 节：24 h 优化调度（MILP，YALMIP 建模）
%
%   res = ies_solve()                       默认参数、储能 'paper' 口径、YALMIP 自动选求解器
%   res = ies_solve(p, mode, solver)
%     p      : ies_params() 返回的参数
%     mode   : 储能首末条件
%              'paper'      按论文作者的实现：S_n(1) = 0（第 1 时段末库存为零，库存下限从第 2
%                           时段起生效），第 1 时段仍须充电 Pcha(1) ≥ 0.2·Pmax_n，但这部分能量
%                           不进入库存，第 2 时段再充 Smin/η 达到下限。论文 Fig.4 中 0:00、1:00
%                           两个时段都在充电（储氢 200 kg、210 kg）正是这种写法的结果
%              'zero_start' 调度开始前库存为 0，第 1 时段的充电计入库存（物理上自洽）
%              'cyclic'     日内循环：S_n(T) = S_n(0)，不需要首时段充电约束
%     solver : 'gurobi' | 'cplex' | 'intlinprog' | 'glpk' | ''（YALMIP 自动选择）
%
%   返回结构体 res：ok, total, costs（COP/CCT/CEP/CWS/CCS）, summary, ts（各逐时序列，T×1）
%
% 目标函数 Eq.(12)：min C = COP + CCT + CEP + CWS + CCS
% 设备 Eq.(1)–(7)，阶梯碳交易 Eq.(8)–(11)，储能 Eq.(19)–(20)，能量平衡 Eq.(21)–(24)

if nargin < 1 || isempty(p),      p = ies_params(); end
if nargin < 2 || isempty(mode),   mode = 'paper';   end
if nargin < 3,                    solver = '';      end
if ~any(strcmp(mode, {'paper', 'zero_start', 'cyclic'}))
    error('mode 只能是 ''paper''、''zero_start'' 或 ''cyclic''');
end

T = p.T;  dt = p.dt;
yalmip('clear');
C = [];

% ---- 外购能源 ----
buy_e = sdpvar(T, 1);  buy_h = sdpvar(T, 1);  buy_g = sdpvar(T, 1);  buy_H = sdpvar(T, 1);  % buy_H: kg/h
C = [C, 0 <= buy_e, 0 <= buy_h, 0 <= buy_g, 0 <= buy_H];
if ~isinf(p.buy_max_e), C = [C, buy_e <= p.buy_max_e]; end
if ~isinf(p.buy_max_h), C = [C, buy_h <= p.buy_max_h]; end
if ~isinf(p.buy_max_g), C = [C, buy_g <= p.buy_max_g]; end
if ~isinf(p.buy_max_H), C = [C, buy_H <= p.buy_max_H]; end

% ---- 风光实际出力 Eq.(18)，弃电量 = 可用 − 实际 ----
wt = sdpvar(T, 1);  pv = sdpvar(T, 1);
C = [C, 0 <= wt <= p.WT_avail, 0 <= pv <= p.PV_avail];
wt_cut = p.WT_avail - wt;
pv_cut = p.PV_avail - pv;

% ---- GT Eq.(1)、WHB Eq.(3) ----
gt_e = sdpvar(T, 1);
gt_g = gt_e / p.eta_GT;
gt_h = gt_e * (1 - p.eta_GT - p.eta_loss) / p.eta_GT;
whb_h = p.eta_WHB * gt_h;
C = [C, 0 <= gt_e <= p.PGT_max, whb_h <= p.PWHB_max];

% ---- GB Eq.(2) ----
gb_h = sdpvar(T, 1);
gb_g = gb_h / p.eta_GB;
C = [C, 0 <= gb_h <= p.PGB_max];

% ---- EL Eq.(4) ----
el_e = sdpvar(T, 1);
el_H = p.eta_EL * el_e / p.meh;
C = [C, 0 <= el_e <= p.PEL_max];

% ---- MR Eq.(5) ----
mr_H = sdpvar(T, 1);
mr_g = p.eta_MR * mr_H * p.meh;
C = [C, 0 <= mr_H <= p.HMR_max];

% ---- HFC Eq.(6) ----
hfc_H = sdpvar(T, 1);
hfc_P = p.eta_HFC * hfc_H * p.meh;
hfc_e = p.eta_HFC_e * hfc_P;
hfc_h = p.eta_HFC_h * hfc_P;
C = [C, 0 <= hfc_H <= p.HHFC_max];

% ---- 爬坡约束：|x(t+1) − x(t)| ≤ ramp · 额定容量 ----
C = [C, -p.ramp_GT  * p.PGT_max  <= diff(gt_e)  <= p.ramp_GT  * p.PGT_max];
C = [C, -p.ramp_GB  * p.PGB_max  <= diff(gb_h)  <= p.ramp_GB  * p.PGB_max];
C = [C, -p.ramp_EL  * p.PEL_max  <= diff(el_e)  <= p.ramp_EL  * p.PEL_max];
C = [C, -p.ramp_MR  * p.HMR_max  <= diff(mr_H)  <= p.ramp_MR  * p.HMR_max];
C = [C, -p.ramp_HFC * p.HHFC_max <= diff(hfc_H) <= p.ramp_HFC * p.HHFC_max];

% ---- CCS Eq.(7) 与实际碳排放 Eq.(9) ----
co2_gt = p.k_GT_e * gt_e + p.k_GT_h * gt_h;
co2_gb = p.k_GB_a * gb_h;
co2 = co2_gt + co2_gb;                 % GT+GB 产生的 CO2
co2_cap = p.eta_CCS * co2;             % 捕集量
co2_uncap = (1 - p.eta_CCS) * co2;     % 未捕集量
ccs_e = p.e_ccs * co2_cap;             % CCS 耗电
co2_mr = p.theta * mr_H;               % MR 利用的 CO2
co2_cs = co2_cap - co2_mr;             % 封存量
C = [C, co2_mr <= co2_cap];            % 0 ≤ E_MR ≤ E_cap

% ---- 储能 Eq.(19)–(20) ----
nS = numel(p.ES.p_max);
cap = repmat(p.ES.p_max, T, 1);        % Pmax_n(t)
for n = 1:nS
    if p.ES.degrade(n)                 % 电储能容量衰减 Eq.(19)
        tt = (1:T)';
        cap(:, n) = p.deg(1) + p.deg(2) * tt - p.deg(3) * tt.^2 - p.deg(4) * sqrt(tt);
    end
end
cha = sdpvar(T, nS, 'full');  dis = sdpvar(T, nS, 'full');  soc = sdpvar(T, nS, 'full');
b_cha = binvar(T, nS, 'full');  b_dis = binvar(T, nS, 'full');
soc0 = sdpvar(1, nS);                  % 调度开始前的库存 S_n(0)
C = [C, 0 <= cha <= 0.3 * cap .* b_cha, 0 <= dis <= 0.3 * cap .* b_dis, b_cha + b_dis <= 1];
for n = 1:nS
    mu = p.ES.mu(n);  ec = p.ES.eta_cha(n);  ed = p.ES.eta_dis(n);
    dyn = soc(2:T, n) == (1 - mu) * soc(1:T-1, n) + ec * cha(2:T, n) - dis(2:T, n) / ed;
    switch mode
        case 'paper'
            C = [C, soc(1, n) == 0, dyn, ...
                 0.2 * cap(2:T, n) <= soc(2:T, n) <= 0.9 * cap(2:T, n), ...
                 cha(1, n) >= 0.2 * cap(1, n)];
        case 'zero_start'
            C = [C, soc(1, n) == ec * cha(1, n) - dis(1, n) / ed, dyn, ...
                 0.2 * cap(:, n) <= soc(:, n) <= 0.9 * cap(:, n), ...
                 cha(1, n) >= 0.2 * cap(1, n)];
        case 'cyclic'
            C = [C, soc(1, n) == (1 - mu) * soc0(n) + ec * cha(1, n) - dis(1, n) / ed, dyn, ...
                 0.2 * cap(:, n) <= soc(:, n) <= 0.9 * cap(:, n), ...
                 0.2 * cap(1, n) <= soc0(n) <= 0.9 * cap(1, n), soc(T, n) == soc0(n)];
    end
end

% ---- 能量平衡 Eq.(21)–(24) ----
C = [C, buy_e + gt_e + hfc_e + dis(:, 1) + wt + pv == p.load_e + el_e + cha(:, 1) + ccs_e];
C = [C, buy_h + whb_h + hfc_h + dis(:, 2) + gb_h == p.load_h + cha(:, 2)];
C = [C, buy_g + mr_g + dis(:, 3) == p.load_g + cha(:, 3) + gt_g + gb_g];
C = [C, buy_H + el_H + dis(:, 4) == mr_H + hfc_H + p.load_H + cha(:, 4)];

% ---- 阶梯碳交易 Eq.(8)、(10)、(11) ----
quota = p.k_buy * buy_e + p.k_GT * gt_g + p.k_GB * gb_g;   % 初始碳配额
co2_env = co2_uncap + p.k_buy_a * buy_e;                   % 排入环境的 CO2
E_a = sum(co2_env - quota);                                % 参与交易的净排放
% 净排放拆成买入量与卖出量，用二进制变量保证二者不同时为正。
% 买入成本是分段线性凸函数，等于 5 条直线的最大值：
%   第 k 段：λ(1+kα)(E − k·l) + λ·l·(k + α·k(k−1)/2)，k = 0..4
% 与 Eq.(11) 各段截距 λl, λl(2+α), λl(3+3α), λl(4+6α) 一致；最小化时 c_buy 自动取到 f(E_buy)。
E_buy = sdpvar(1);  E_sell = sdpvar(1);  y_buy = binvar(1);  c_buy = sdpvar(1);
M = 1e5;
C = [C, E_a == E_buy - E_sell, 0 <= E_buy <= M * y_buy, 0 <= E_sell <= M * (1 - y_buy), c_buy >= 0];
for k = 0:4
    slope = p.lam * (1 + k * p.alpha_step);
    icpt = p.lam * p.l_step * (k + p.alpha_step * k * (k - 1) / 2);
    C = [C, c_buy >= slope * (E_buy - k * p.l_step) + icpt];
end
CCT = c_buy - p.sell_factor * p.lam * E_sell;

% ---- 目标函数 Eq.(12)–(17) ----
if strcmp(p.om_basis, 'capacity')
    om_conv = p.a_GT * p.PGT_max + p.a_GB * p.PGB_max + p.a_WHB * p.PWHB_max ...
            + p.a_EL * p.PEL_max + p.a_MR * p.HMR_max + p.a_HFC * p.HHFC_max;
elseif strcmp(p.om_basis, 'energy')
    om_conv = dt * sum(p.a_GT * gt_e + p.a_GB * gb_h + p.a_WHB * whb_h ...
                       + p.a_EL * el_e + p.a_MR * mr_g + p.a_HFC * hfc_P);
else
    error('om_basis 只能是 ''capacity'' 或 ''energy''');
end
om_other = dt * (sum(p.a_CCS * ccs_e + p.a_WT * wt + p.a_PV * pv) ...
                 + sum((cha + dis) * p.ES.alpha'));
COP = om_conv + om_other;
CEP = dt * sum(p.price_elec .* buy_e + p.price_heat * buy_h + p.price_gas * buy_g ...
               + p.price_H2 * p.meh * buy_H);
CWS = dt * sum(p.pen_WT * wt_cut + p.pen_PV * pv_cut);
CCS = sum(p.k_cs * co2_cs);
obj = COP + CCT + CEP + CWS + CCS;

% ---- 求解 ----
ops = sdpsettings('verbose', 0);
if ~isempty(solver)
    ops = sdpsettings(ops, 'solver', solver);
    if strcmp(solver, 'gurobi'), ops = sdpsettings(ops, 'gurobi.MIPGap', 1e-6); end
    if strcmp(solver, 'cplex'),  ops = sdpsettings(ops, 'cplex.mip.tolerances.mipgap', 1e-6); end
end
sol = optimize(C, obj, ops);

res.p = p;
res.mode = mode;
res.ok = sol.problem == 0;
res.info = sol.info;
if ~res.ok
    res.total = NaN;
    warning('求解失败：%s', sol.info);
    return
end

v = @(x) double(value(x));
res.total = v(obj);
res.costs = struct('COP', v(COP), 'CCT', v(CCT), 'CEP', v(CEP), 'CWS', v(CWS), 'CCS', v(CCS));

ts.t = (0:T-1)';
% 电
ts.E_Load = p.load_e;  ts.E_Buy = v(buy_e);  ts.WT = v(wt);  ts.PV = v(pv);
ts.GT_e = v(gt_e);  ts.HFC_e = v(hfc_e);  ts.EL_e = v(el_e);  ts.CCS_e = v(ccs_e);
ts.WT_cut = v(wt_cut);  ts.PV_cut = v(pv_cut);
% 热
ts.H_Load = p.load_h;  ts.H_Buy = v(buy_h);  ts.WHB_h = v(whb_h);  ts.GB_h = v(gb_h);  ts.HFC_h = v(hfc_h);
% 气
ts.G_Load = p.load_g;  ts.G_Buy = v(buy_g);  ts.MR_g = v(mr_g);  ts.GT_g = v(gt_g);  ts.GB_g = v(gb_g);
% 氢
ts.H2_Load = p.load_H;  ts.H2_Buy = v(buy_H);  ts.EL_H2 = v(el_H);  ts.HFC_H2 = v(hfc_H);  ts.MR_H2 = v(mr_H);
% 储能（列 1–4：电、热、气、氢）
ts.ES_cha = v(cha);  ts.ES_dis = v(dis);  ts.SOC = v(soc);
% 碳
ts.CO2_GT = v(co2_gt);  ts.CO2_GB = v(co2_gb);  ts.CO2_cap = v(co2_cap);  ts.CO2_uncap = v(co2_uncap);
ts.CO2_MR = v(co2_mr);  ts.CO2_CS = v(co2_cs);  ts.CO2_env = v(co2_env);
res.ts = ts;

s.CO2_gen = sum(ts.CO2_GT + ts.CO2_GB);          % CO2 产生量 / t
s.CO2_emit = sum(ts.CO2_uncap);                  % CO2 排放量 / t
s.CCS_elec = sum(ts.CCS_e);                      % CCS 耗电 / MWh
s.E_trade = v(E_a);                              % 参与交易的净排放 / t
s.curtail = sum(ts.WT_cut + ts.PV_cut);          % 弃风弃光 / MWh
s.dS = ts.SOC(1, :) - ts.SOC(T, :);              % ΔS_n = S_n(1) − S_n(T)
res.summary = s;
end

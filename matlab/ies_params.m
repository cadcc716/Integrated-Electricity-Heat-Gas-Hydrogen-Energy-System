function p = ies_params(varargin)
% IES_PARAMS  电–热–气–氢综合能源系统参数（论文 Table 1–3、Fig.2–3）
%
%   p = ies_params()                     默认参数，复现论文报告的结果
%   p = ies_params('literal')            完全按论文公式字面实现（出售价 λ、运维按出力计）
%   p = ies_params('PEL_max', 60.6)      修改任意参数（可与 'literal' 连用）
%
% 默认参数与论文公式字面写法不同的两处（依据见 README）：
%   sell_factor = 2        论文报告的碳交易收益恰好等于 2λ × 富余配额
%   om_basis = 'capacity'  GT/GB/WHB/EL/MR/HFC 运维成本按 α_i × 额定容量计

p.T = 24;           % 调度时段数
p.dt = 1;           % 时段长度（h）

% ---- 燃气轮机 GT ----
p.PGT_max = 580;    p.ramp_GT = 0.2;   p.eta_GT = 0.35;   p.eta_loss = 0.1;   p.a_GT = 12.5;
% ---- 燃气锅炉 GB ----
p.PGB_max = 1000;   p.ramp_GB = 0.2;   p.eta_GB = 0.75;   p.a_GB = 85;
% ---- 余热锅炉 WHB ----
p.PWHB_max = 600;   p.eta_WHB = 0.75;  p.a_WHB = 65;
% ---- 电解槽 EL ----
p.PEL_max = 5;      p.ramp_EL = 0.2;   p.eta_EL = 0.75;   p.a_EL = 25;
p.meh = 0.03954;    % 氢气热值（MWh/kg）
% ---- 甲烷发生器 MR ----
p.HMR_max = 1000;   p.ramp_MR = 0.2;   p.eta_MR = 0.6;    p.a_MR = 19;
p.theta = 0.00135;  % MR 的 CO2 利用系数（t/kg）
% ---- 氢燃料电池 HFC ----
p.HHFC_max = 25;    p.ramp_HFC = 0.2;  p.eta_HFC = 0.95;
p.eta_HFC_e = 0.8;  p.eta_HFC_h = 0.15; p.a_HFC = 18;
% ---- 碳捕集 CCS ----
p.eta_CCS = 0.65;   p.e_ccs = 0.269;   p.k_cs = 1.4;      p.a_CCS = 55;   % a_CCS 按耗电量计
% ---- 风电 / 光伏 ----
p.a_WT = 70;        p.a_PV = 32;       % 按实际出力计
p.pen_WT = 200;     p.pen_PV = 200;    % 弃风弃光惩罚 ¥/MWh
% ---- 碳配额系数与实际排放系数（kg/kWh = t/MWh）----
p.k_buy = 0.68;     p.k_GT = 0.612;    p.k_GB = 0.306;
p.k_buy_a = 1.08;   p.k_GT_e = 0.195;  p.k_GT_h = 0.39;   p.k_GB_a = 0.195;
% ---- 阶梯碳交易 ----
p.lam = 250;        p.l_step = 100;    p.alpha_step = 0.25;
p.sell_factor = 2;          % 富余配额出售价 = sell_factor·λ（Eq.(11) 字面为 1）
p.om_basis = 'capacity';    % 'capacity' | 'energy'（Eq.(13) 字面写法）
% ---- 能源价格 ----
p.price_gas = 350;  p.price_H2 = 1500;  p.price_heat = 1000;   % ¥/MWh
p.price_elec = [343.8*ones(1,7), 680*ones(1,4), 811*ones(1,3), 680*ones(1,3), ...
                811*ones(1,5), 380*ones(1,2)]';                % Table 3
% ---- 外购上限（论文未给出数值，Inf 表示不限）----
p.buy_max_e = Inf;  p.buy_max_h = Inf;  p.buy_max_g = Inf;  p.buy_max_H = Inf;
% ---- 储能（Table 2，Eq.(19)–(20)）----
% 所有限值都按 Pmax_n 的比例给出：充放功率 ≤ 0.3·Pmax_n，库存 0.2~0.9·Pmax_n，
% 首时段充电 ≥ 0.2·Pmax_n。Table 2 的数值就是这些比例的结果，不要再乘 0.3。
p.ES.name    = {'电储能', '热储能', '气储能', '氢储能'};
p.ES.p_max   = [200, 200, 100, 1000];     % Pmax_n（MWh 或 kg）
p.ES.eta_cha = [0.95, 0.95, 0.95, 0.95];
p.ES.eta_dis = [0.95, 0.95, 0.95, 0.95];
p.ES.mu      = [0.001, 0, 0, 0];          % 自放电率
p.ES.alpha   = [18, 16, 16, 16];          % 运维成本，按充放电量计
p.ES.degrade = [true, false, false, false];
p.deg = [200, 4.168e-4, 1.9984e-7, 0.0332];   % Eq.(19) 的 a, b, c, d
% ---- 风光出力（读自 Fig.2）与负荷（读自 Fig.3）----
p.WT_avail = [20 33 36 46 47 43 40 50 38 34 48 31 38 29 11 8 32 47 33 42 52 50 59 42.5]';
p.PV_avail = [0 0 0 0 0 0 0 0 0 17 30 40 45 46 43 33 21 8 0 0 0 0 0 0]';
p.load_e   = [15 25 26 28 28 32 35 41 43 49 55 68 66 56 43 42 47 51 53 54 50 39 30 27]';
p.load_h   = [45 24 38 48 51 58 43 58 68 83 80 84 70 68 65 62 65 88 50 48 45 55 63 50]';
p.load_H   = [80 66 60 50 50 55 55 100 152 136 80 70 70 70 90 90 80 70 70 70 70 70 70 70]';  % kg/h
p.load_g   = [10 13 12 11 14 15 14 15 13 10 12 15 15 15 14 13 11 11 12 12 13 10 9 8]';

% ---- 参数修改 ----
args = varargin;
if ~isempty(args) && ischar(args{1}) && strcmp(args{1}, 'literal')
    p.sell_factor = 1;
    p.om_basis = 'energy';
    args = args(2:end);
end
if mod(numel(args), 2) ~= 0
    error('参数须成对给出：ies_params(''名称'', 值, ...)');
end
for k = 1:2:numel(args)
    if ~isfield(p, args{k})
        error('未知参数：%s', args{k});
    end
    p.(args{k}) = args{k + 1};
end
end

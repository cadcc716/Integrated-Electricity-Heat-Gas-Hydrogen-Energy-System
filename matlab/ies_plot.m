function ies_plot(res, outdir)
% IES_PLOT  电/热/气/氢平衡与碳捕集/封存共 6 张图（对应论文 Fig.4(a)–(f)）
%
%   ies_plot(res)            在屏幕上显示
%   ies_plot(res, 'pic')     同时把 PNG 保存到 pic/ 目录

if nargin < 2, outdir = ''; end
if ~isempty(outdir) && ~exist(outdir, 'dir'), mkdir(outdir); end
ts = res.ts;
f = @(name) fullfile_or_empty(outdir, name);

balance_fig(ts.t, ...
    {'外部购电', '风机出力', '光伏出力', '燃气轮机', '氢燃料电池', '蓄电池放电'}, ...
    [ts.E_Buy, ts.WT, ts.PV, ts.GT_e, ts.HFC_e, ts.ES_dis(:, 1)], ...
    {'电解槽耗电', '蓄电池充电', '碳捕集耗电'}, [ts.EL_e, ts.ES_cha(:, 1), ts.CCS_e], ...
    ts.E_Load, '电负荷能量平衡图', 'Power/MW', f('elec_balance.png'));
balance_fig(ts.t, ...
    {'外部购热', '余热锅炉', '燃气锅炉', '氢燃料电池热', '蓄热放热'}, ...
    [ts.H_Buy, ts.WHB_h, ts.GB_h, ts.HFC_h, ts.ES_dis(:, 2)], ...
    {'蓄热储热'}, ts.ES_cha(:, 2), ...
    ts.H_Load, '热负荷能量平衡图', 'Power/MW', f('heat_balance.png'));
balance_fig(ts.t, ...
    {'外部购气', '甲烷发生器', '储气放气'}, [ts.G_Buy, ts.MR_g, ts.ES_dis(:, 3)], ...
    {'储气充气', '燃气轮机耗气', '燃气锅炉耗气'}, [ts.ES_cha(:, 3), ts.GT_g, ts.GB_g], ...
    ts.G_Load, '天然气平衡分析图', 'Power/MW', f('gas_balance.png'));
balance_fig(ts.t, ...
    {'外部购氢', '电解槽制氢', '储氢放氢'}, [ts.H2_Buy, ts.EL_H2, ts.ES_dis(:, 4)], ...
    {'储氢充氢', '燃料电池耗氢', '甲烷发生器耗氢'}, [ts.ES_cha(:, 4), ts.HFC_H2, ts.MR_H2], ...
    ts.H2_Load, '氢能平衡分析图', 'Mass/kg', f('hydrogen_balance.png'));
balance_fig(ts.t, {'CCS', 'Non-CCS'}, [ts.CO2_cap, ts.CO2_uncap], ...
    {'GT', 'GB'}, [ts.CO2_GT, ts.CO2_GB], ...
    [], 'Carbon Capture Status', 'Mass/t', f('carbon_cap.png'));
balance_fig(ts.t, {'Carbon Capture'}, ts.CO2_cap, ...
    {'Carbon Storage', 'MR'}, [ts.CO2_CS, ts.CO2_MR], ...
    [], 'Carbon Storage Status', 'Mass/t', f('carbon_storage.png'));
end

function path = fullfile_or_empty(outdir, name)
if isempty(outdir), path = ''; else, path = fullfile(outdir, name); end
end

function balance_fig(t, posNames, posVals, negNames, negVals, load, ttl, ylab, path)
fig = figure('Color', 'w', 'Position', [100, 100, 609, 521]);
hold on;
hp = bar(t, posVals, 0.8, 'stacked');
hn = bar(t, -negVals, 0.8, 'stacked');
paint(hp, posNames);
paint(hn, negNames);
handles = [hp(:); hn(:)];
labels = [posNames, negNames];
if ~isempty(load)
    hl = plot(t, load, '-o', 'Color', [0.93, 0.11, 0.14], 'LineWidth', 1.5, 'MarkerSize', 4);
    handles = [handles; hl];
    labels = [labels, {'负荷需求'}];
end
plot([t(1) - 1, t(end) + 1], [0, 0], 'k-', 'LineWidth', 0.8, 'HandleVisibility', 'off');
xlim([t(1) - 1, t(end) + 1]);
title(ttl, 'FontWeight', 'bold');
xlabel('Time/hour');
ylabel(ylab);
box on;
set(gca, 'TickDir', 'in');
try
    legend(handles, labels, 'Location', 'southoutside', 'NumColumns', 3);
catch   % Octave 不支持 NumColumns
    legend(handles, labels, 'Location', 'eastoutside');
end
hold off;
if ~isempty(path)
    print(fig, path, '-dpng', '-r150');
end
end

function paint(h, names)
for i = 1:numel(h)
    set(h(i), 'FaceColor', color_of(names{i}), 'EdgeColor', 'k', 'LineWidth', 0.5);
end
end

function c = color_of(name)
persistent cmap
if isempty(cmap)
    keys = {'外部购电', '外部购气', '外部购氢', '外部购热', '风机出力', '光伏出力', ...
            '燃气轮机', '燃气锅炉', '甲烷发生器', '余热锅炉', '电解槽制氢', '碳捕集耗电', ...
            '氢燃料电池', '氢燃料电池热', '蓄电池放电', '蓄热放热', '储气放气', '储氢放氢', ...
            '蓄电池充电', '蓄热储热', '储气充气', '储氢充氢', '电解槽耗电', '燃气轮机耗气', ...
            '燃气锅炉耗气', '燃料电池耗氢', '甲烷发生器耗氢', 'CCS', 'Non-CCS', 'GT', 'GB', ...
            'Carbon Capture', 'Carbon Storage', 'MR'};
    hex = {'00AEEF', '00AEEF', '00AEEF', '00AEEF', 'FFC000', '0A562C', ...
           'ED1C24', 'ED1C24', 'F4B183', '00B050', '00B050', '92D050', ...
           '99CCFF', '99CCFF', '7F7F7F', '7F7F7F', '7F7F7F', '7F7F7F', ...
           'FF3399', 'FF3399', 'FF3399', 'FF3399', '7030A0', '0700CD', ...
           '7030A0', '7030A0', 'C55A11', '3399FF', 'C55A11', '33CC33', 'FF1F1F', ...
           '3399FF', '33CC33', 'FF1F1F'};
    cmap = containers.Map(keys, hex);
end
if isKey(cmap, name), h = cmap(name); else, h = 'A6A6A6'; end
c = [hex2dec(h(1:2)), hex2dec(h(3:4)), hex2dec(h(5:6))] / 255;
end

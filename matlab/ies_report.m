function ies_report(res)
% IES_REPORT  打印调度结果，并与论文第 4 节报告值逐项对比

c = res.costs;  s = res.summary;
z = @(x) x .* (abs(x) > 1e-6);   % 去掉求解器残留的 -0.00
fprintf('调度总成本 / ¥: %s\n', fmt(res.total));
fprintf('  外购能源成本 CEP / ¥: %s\n', fmt(c.CEP));
fprintf('  运维成本 COP / ¥: %s\n', fmt(c.COP));
fprintf('  阶梯碳交易成本 CCT / ¥: %s\n', fmt(c.CCT));
fprintf('  弃风弃光惩罚 CWS / ¥: %s\n', fmt(z(c.CWS)));
fprintf('  碳封存成本 CCS / ¥: %s\n', fmt(c.CCS));
fprintf('  参与交易净排放 / t: %.2f\n', s.E_trade);
fprintf('  弃风弃光 / MWh: %.2f\n', z(s.curtail));
names = res.p.ES.name;
for n = 1:numel(names)
    fprintf('  ΔS%d %s S(1)−S(T): %.2f\n', n, names{n}, z(s.dS(n)));
end

% 论文第 4 节报告的基准调度结果
label = {'总成本', '外购能源成本 CEP', '运维成本 COP', '碳交易成本 CCT', '弃风弃光成本 CWS', ...
         '碳封存成本 CCS', 'CO2 产生量 / t', 'CO2 排放量 / t', 'CCS 耗电 / MWh'};
paper = [847510.4, 907654.7, 271766.2, -341820.2, 9558.5, 351.1, 386.8273, 135.3896, 67.0];
ours = [res.total, c.CEP, c.COP, c.CCT, z(c.CWS), c.CCS, s.CO2_gen, s.CO2_emit, s.CCS_elec];
fprintf('\n与论文第 4 节结果对比：\n');
fprintf('%-18s %14s %14s %10s\n', '指标', '本模型', '论文', '偏差 %');
for k = 1:numel(label)
    fprintf('%-18s %14s %14s %10.2f\n', label{k}, fmt(ours(k)), fmt(paper(k)), ...
            (ours(k) - paper(k)) / abs(paper(k)) * 100);
end
end

function s = fmt(x)
% 千分位格式，保留 1 位小数
neg = x < 0;
s = sprintf('%.1f', abs(x));
dot = strfind(s, '.');
intpart = s(1:dot-1);
n = numel(intpart);
for k = n-3:-3:1
    intpart = [intpart(1:k), ',', intpart(k+1:end)];
end
s = [intpart, s(dot:end)];
if neg, s = ['-', s]; end
end

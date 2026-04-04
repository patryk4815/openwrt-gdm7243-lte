'use strict';
'require view';
'require poll';
'require rpc';

var callGctdSignal = rpc.declare({
	object: 'gctd',
	method: 'signal',
	expect: {}
});

function formatFixed(val) {
	if (val === null || val === undefined) return '-';
	var abs = Math.abs(val);
	return (val < 0 ? '-' : '') + Math.floor(abs / 10) + '.' + (abs % 10);
}

function row(label, id) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '200px' }, E('strong', {}, label)),
		E('td', { 'class': 'td left', 'id': id }, '-')
	]);
}

function setText(id, text) {
	var el = document.getElementById(id);
	if (el) el.textContent = text || '-';
}

return view.extend({
	render: function() {
		var signalTable = E('table', { 'class': 'table' }, [
			row('Band', 'gctd-band'),
			row('EARFCN', 'gctd-earfcn'),
			row('Cell', 'gctd-cell'),
			row('PLMN', 'gctd-plmn'),
			row('RSRP', 'gctd-rsrp'),
			row('RSRQ', 'gctd-rsrq'),
			row('RSSI', 'gctd-rssi'),
			row('SINR', 'gctd-sinr'),
			row('CINR', 'gctd-cinr'),
			row('TX Power', 'gctd-txpwr'),
			row('Temperature', 'gctd-temp')
		]);

		var carrierDiv = E('div', { 'id': 'gctd-carriers' },
			E('em', {}, 'No carrier aggregation active'));

		var body = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, 'LTE Signal'),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, 'Primary Cell'),
				signalTable
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, 'Carrier Aggregation'),
				carrierDiv
			])
		]);

		poll.add(function() {
			return callGctdSignal().then(function(data) {
				if (!data || data.error) {
					setText('gctd-band', data && data.error ? data.error : 'Not available');
					return;
				}

				setText('gctd-band', 'B' + data.band + ' (' + data.bandwidth + ' MHz)');
				setText('gctd-earfcn', data.dl_earfcn + ' / ' + data.ul_earfcn);
				setText('gctd-cell', 'PCI ' + data.pci + '  ID ' + data.cell_id + '  TAC ' + data.tac);
				setText('gctd-plmn', data.mcc + '/' + String(data.mnc).padStart(2, '0'));

				if (data.rsrp)
					setText('gctd-rsrp', data.rsrp[0] + ' / ' + data.rsrp[1] + ' dBm (avg ' + data.rsrp_avg + ')');
				if (data.rsrq)
					setText('gctd-rsrq', data.rsrq[0] + ' / ' + data.rsrq[1] + ' dB (avg ' + data.rsrq_avg + ')');
				if (data.rssi)
					setText('gctd-rssi', data.rssi[0] + ' / ' + data.rssi[1] + ' dBm (avg ' + data.rssi_avg + ')');

				setText('gctd-sinr', data.sinr + ' dB');

				if (data.cinr)
					setText('gctd-cinr', formatFixed(data.cinr[0]) + ' / ' + formatFixed(data.cinr[1]) + ' dB');

				setText('gctd-txpwr', formatFixed(data.tx_power) + ' dBm');
				setText('gctd-temp', data.temperature + ' °C');

				// Carrier Aggregation
				var div = document.getElementById('gctd-carriers');
				if (!div) return;
				while (div.firstChild) div.removeChild(div.firstChild);

				if (!data.carriers || data.carriers.length === 0) {
					div.appendChild(E('em', {}, 'No carrier aggregation active'));
					return;
				}

				var table = E('table', { 'class': 'table' }, [
					E('tr', { 'class': 'tr' }, [
						E('th', { 'class': 'th' }, 'SCC'),
						E('th', { 'class': 'th' }, 'PCI'),
						E('th', { 'class': 'th' }, 'BW'),
						E('th', { 'class': 'th' }, 'Freq'),
						E('th', { 'class': 'th' }, 'RSRP'),
						E('th', { 'class': 'th' }, 'RSRQ'),
						E('th', { 'class': 'th' }, 'RSSI'),
						E('th', { 'class': 'th' }, 'CINR')
					])
				]);

				data.carriers.forEach(function(c) {
					table.appendChild(E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, String(c.scc_idx)),
						E('td', { 'class': 'td' }, String(c.pci)),
						E('td', { 'class': 'td' }, c.bandwidth + ' MHz'),
						E('td', { 'class': 'td' }, formatFixed(c.frequency) + ' MHz'),
						E('td', { 'class': 'td' }, c.rsrp[0] + ' / ' + c.rsrp[1]),
						E('td', { 'class': 'td' }, c.rsrq[0] + ' / ' + c.rsrq[1]),
						E('td', { 'class': 'td' }, c.rssi[0] + ' / ' + c.rssi[1]),
						E('td', { 'class': 'td' }, c.cinr[0] + ' / ' + c.cinr[1])
					]));
				});

				div.appendChild(table);
			});
		}, 10);

		return body;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});

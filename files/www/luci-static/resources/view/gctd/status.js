'use strict';
'require view';
'require poll';
'require rpc';

var callGctdStatus = rpc.declare({
	object: 'gctd',
	method: 'status',
	expect: {}
});

function signalBar(bars, index) {
	var heights = [25, 45, 65, 85];
	var active = index < bars;
	return E('div', {
		'style': 'display:inline-block;width:8px;height:' + heights[index] + '%;' +
			'margin-right:3px;vertical-align:bottom;border-radius:2px;' +
			'background-color:' + (active ? '#4CAF50' : '#e0e0e0') + ';'
	});
}

function simLabel(sim) {
	var map = {
		'ready': 'Ready',
		'pin_required': 'PIN required',
		'puk_required': 'PUK required',
		'unknown': 'Unknown'
	};
	return map[sim] || sim || '-';
}

function regLabel(reg) {
	var map = {
		'home': 'Registered (home)',
		'roaming': 'Registered (roaming)',
		'searching': 'Searching...',
		'denied': 'Denied',
		'not_registered': 'Not registered',
		'unknown': 'Unknown'
	};
	return map[reg] || reg || '-';
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
		var statusTable = E('table', { 'class': 'table' }, [
			row('SIM', 'gctd-sim'),
			row('Registration', 'gctd-reg'),
			row('Operator', 'gctd-oper'),
			row('Signal', 'gctd-signal'),
			row('IP Address', 'gctd-ip'),
			row('Gateway', 'gctd-gw'),
			row('DNS', 'gctd-dns'),
			row('MTU', 'gctd-mtu')
		]);

		var body = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, 'LTE Modem Status'),
			E('div', { 'class': 'cbi-section' }, [statusTable])
		]);

		poll.add(function() {
			return callGctdStatus().then(function(data) {
				if (!data || data.error) {
					setText('gctd-sim', data && data.error ? data.error : 'Not available');
					return;
				}

				setText('gctd-sim', simLabel(data.sim));
				setText('gctd-reg', regLabel(data.registration));
				setText('gctd-oper', data.operator);

				var sigEl = document.getElementById('gctd-signal');
				if (sigEl) {
					while (sigEl.firstChild)
						sigEl.removeChild(sigEl.firstChild);

					if (data.signal_dbm !== null && data.signal_dbm !== undefined) {
						var barContainer = E('div', {
							'style': 'display:inline-flex;align-items:flex-end;height:24px;margin-right:8px;'
						});
						for (var i = 0; i < 4; i++)
							barContainer.appendChild(signalBar(data.signal_bars, i));

						sigEl.appendChild(barContainer);
						sigEl.appendChild(document.createTextNode(
							data.signal_dbm + ' dBm (' + data.signal_bars + '/4)'));
					} else {
						sigEl.textContent = 'Unknown';
					}
				}

				var ipText = data.ip || '-';
				if (data.prefix) ipText += '/' + data.prefix;
				setText('gctd-ip', ipText);
				setText('gctd-gw', data.gateway);

				var dns = [];
				if (data.dns1) dns.push(data.dns1);
				if (data.dns2) dns.push(data.dns2);
				setText('gctd-dns', dns.join(', ') || '-');

				setText('gctd-mtu', data.mtu || '-');
			});
		}, 10);

		return body;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});

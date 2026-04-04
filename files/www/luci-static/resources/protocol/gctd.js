'use strict';
'require rpc';
'require form';
'require network';

return network.registerProtocol('gctd', {
	getI18n: function() {
		return _('GCT LTE (gctd)');
	},

	getIfname: function() {
		return this._ubus('l3_device') || this._ubus('device') || 'wan.100';
	},

	getOpkgPackage: function() {
		return null;
	},

	isFloating: function() {
		return false;
	},

	isVirtual: function() {
		return false;
	},

	renderFormOptions: function(s) {
		var o;

		o = s.taboption('general', form.Value, 'apn', _('APN'),
			_('Access Point Name for the LTE connection'));
		o.placeholder = 'internet';

		o = s.taboption('general', form.ListValue, 'pdptype', _('PDP Type'),
			_('IP protocol for the PDP context'));
		o.value('ip', 'IPv4');
		o.value('ipv6', 'IPv6');
		o.value('ipv4v6', 'IPv4v6 (Dual Stack)');
		o.default = 'ip';

		o = s.taboption('general', form.Value, 'pin', _('SIM PIN'),
			_('SIM card PIN code (leave empty if not needed)'));
		o.password = true;
		o.rmempty = true;

		o = s.taboption('general', form.ListValue, 'auth', _('Authentication'),
			_('APN authentication method'));
		o.value('none', _('None'));
		o.value('pap', 'PAP');
		o.value('chap', 'CHAP');
		o.default = 'none';

		o = s.taboption('general', form.Value, 'username', _('Username'),
			_('APN authentication username'));
		o.depends('auth', 'pap');
		o.depends('auth', 'chap');
		o.rmempty = true;

		o = s.taboption('general', form.Value, 'password', _('Password'),
			_('APN authentication password'));
		o.depends('auth', 'pap');
		o.depends('auth', 'chap');
		o.password = true;
		o.rmempty = true;

		o = s.taboption('advanced', form.Value, 'cid', _('PDP Context ID'),
			_('CID for the LTE data connection'));
		o.datatype = 'range(1,8)';
		o.default = '3';

		o = s.taboption('advanced', form.Flag, 'allow_roaming', _('Allow Roaming'),
			_('Allow connection when the modem is roaming'));
		o.default = '1';

		o = s.taboption('advanced', form.Flag, 'leds', _('LED Control'),
			_('Control signal strength and LTE status LEDs'));
		o.default = '1';

		o = s.taboption('advanced', form.Flag, 'use_apn_dns', _('Use APN DNS'),
			_('Use DNS servers provided by the mobile network'));
		o.default = '1';
	}
});

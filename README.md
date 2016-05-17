Overview
==========

This is a SMTP backend for [Lager](https://github.com/basho/lager).
It allows you to send email messages out of lager via SMTP server.

Configuration
==========
This backend is configured using proplist with contents similar to the following example:

	{lager_smtp_backend, [
		{level, error},
        {from, <<"from@example.com">>},
		{to, [<<"to@example.com">>]},
		{relay, <<"smtp.example.com">>},
		{username, <<"from@example.com">>},
		{password, <<"secret_password">>},
		{port, 587},
		{ssl, true},
        {flush, true},
		{flush_interval, 20000}
	]}

Note that **to** is a list of recipients, that is mandatory.
Mandatory arguments are only **from**, **to** and **relay**, example shows defaults.

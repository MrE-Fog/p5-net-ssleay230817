use lib 'inc';

use Net::SSLeay;
use Test::Net::SSLeay qw(tcp_socket);

use Config;
use File::Spec;

BEGIN {
    if (!$Config{d_fork}) {
        plan skip_all => "fork() not supported on $^O";
    } else {
        plan tests => 122;
    }
}

$SIG{'PIPE'} = 'IGNORE';

my $server = tcp_socket();
my $pid;

my $msg = 'ssleay-test';
my $ca_cert_pem = File::Spec->catfile('t', 'data', 'test_CA1_2048.crt.pem');
my $cert_pem = File::Spec->catfile('t', 'data', 'testcert_wildcard_CA1_2048.crt.pem');
my $key_pem = File::Spec->catfile('t', 'data', 'testcert_key_2048.pem');

my $cert_name = (Net::SSLeay::SSLeay >= 0x0090700f) ?
                '/C=US/ST=State/L=City/O=Company/OU=Unit/CN=*.example.com/emailAddress=wildcard@example.com' :
                '/C=US/ST=State/L=City/O=Company/OU=Unit/CN=*.example.com/Email=wildcard@example.com';
my $cert_issuer = '/C=US/O=Demo1/CN=CA1';
my $cert_sha1_fp = '91:41:FD:7D:99:02:2E:70:91:53:EF:C6:F3:F8:9D:E2:CF:B0:5F:0C';

$ENV{RND_SEED} = '1234567890123456789012345678901234567890';

Net::SSLeay::randomize();
Net::SSLeay::load_error_strings();
Net::SSLeay::ERR_load_crypto_strings();
Net::SSLeay::library_init();

{
    my $ctx = Net::SSLeay::CTX_new();
    ok($ctx, 'CTX_new');
    ok(Net::SSLeay::CTX_set_cipher_list($ctx, 'ALL'), 'CTX_set_cipher_list');
    my ($dummy, $errs) = Net::SSLeay::set_cert_and_key($ctx, $cert_pem, $key_pem);
    ok($errs eq '', "set_cert_and_key: $errs");
    SKIP: {
        skip 'Disabling session tickets requires OpenSSL >= 1.1.1', 1
	    unless defined (&Net::SSLeay::CTX_set_num_tickets);
        # TLS 1.3 server sends session tickets after a handhake as part of
        # the SSL_accept(). If a client finishes all its job including closing
        # TCP connection before a server sends the tickets, SSL_accept() fails
        # with SSL_ERROR_SYSCALL and EPIPE errno and the server receives
        # SIGPIPE signal. <https://github.com/openssl/openssl/issues/6904>
	ok(Net::SSLeay::CTX_set_num_tickets($ctx, 0), 'Session tickets disabled');
    }

    $pid = fork();
    BAIL_OUT("failed to fork: $!") unless defined $pid;
    if ($pid == 0) {
        for (1 .. 7) {
            my $ns = $server->accept();

            my $ssl = Net::SSLeay::new($ctx);
            ok($ssl, 'new');

	    is(Net::SSLeay::in_before($ssl), 1, 'in_before is 1');
	    is(Net::SSLeay::in_init($ssl), 1, 'in_init is 1');

            ok(Net::SSLeay::set_fd($ssl, fileno($ns)), 'set_fd using fileno');
            ok(Net::SSLeay::accept($ssl), 'accept');

	    is(Net::SSLeay::is_init_finished($ssl), 1, 'is_init_finished is 1');

            ok(Net::SSLeay::get_cipher($ssl), 'get_cipher');
            like(Net::SSLeay::get_shared_ciphers($ssl), qr/(AES|RSA|SHA|CBC|DES)/, 'get_shared_ciphers');

            my $got = Net::SSLeay::ssl_read_all($ssl);
            is($got, $msg, 'ssl_read_all') if $_ < 7;

	    is(Net::SSLeay::get_shutdown($ssl), Net::SSLeay::RECEIVED_SHUTDOWN(), 'shutdown from peer');
            ok(Net::SSLeay::ssl_write_all($ssl, uc($got)), 'ssl_write_all');

	    # With 1.1.1e and $Net::SSLeay::trace=3 you'll see these without shutdown:
	    # SSL_read 9740: 1 - error:14095126:SSL routines:ssl3_read_n:unexpected eof while reading
	    my $sret = Net::SSLeay::shutdown($ssl);
	    if ($sret < 0)
	    {
		# ERROR_SYSCALL seen on < 1.1.1, if so also print errno string
		my $err = Net::SSLeay::get_error($ssl, $sret);
		my $extra = ($err == Net::SSLeay::ERROR_SYSCALL()) ? "$err, $!" : "$err";

		ok($err == Net::SSLeay::ERROR_ZERO_RETURN() ||
		   $err == Net::SSLeay::ERROR_SYSCALL(),
		    "server shutdown not success, but acceptable: $extra");
	    }
	    else
	    {
		pass('server shutdown success');
	    }

            Net::SSLeay::free($ssl);
            close $ns;
        }

        Net::SSLeay::CTX_free($ctx);
        $server->close();

        exit;
    }
}

my @results;
{
    my ($got) = Net::SSLeay::sslcat($server->get_addr(), $server->get_port(), $msg);
    push @results, [ $got eq uc($msg), 'send and received correctly' ];

}

{
    my $s = $server->connect();

    push @results, [ my $ctx = Net::SSLeay::CTX_new(), 'CTX_new' ];
    push @results, [ my $ssl = Net::SSLeay::new($ctx), 'new' ];

    push @results, [ Net::SSLeay::set_fd($ssl, $s), 'set_fd using glob ref' ];
    push @results, [ Net::SSLeay::connect($ssl), 'connect' ];

    push @results, [ Net::SSLeay::get_cipher($ssl), 'get_cipher' ];

    push @results, [ Net::SSLeay::ssl_write_all($ssl, $msg), 'write' ];
    push @results, [ Net::SSLeay::shutdown($ssl) >= 0, 'client side ssl shutdown' ];
    shutdown($s, 1);

    my $got = Net::SSLeay::ssl_read_all($ssl);
    push @results, [ $got eq uc($msg), 'read' ];

    Net::SSLeay::free($ssl);
    Net::SSLeay::CTX_free($ctx);

    shutdown($s, 2);
    close $s;

}

{
    my $verify_cb_1_called = 0;
    my $verify_cb_2_called = 0;
    my $verify_cb_3_called = 0;
    {
        my $ctx = Net::SSLeay::CTX_new();
        push @results, [ Net::SSLeay::CTX_load_verify_locations($ctx, $ca_cert_pem, ''), 'CTX_load_verify_locations' ];
        Net::SSLeay::CTX_set_verify($ctx, &Net::SSLeay::VERIFY_PEER, \&verify);

        my $ctx2 = Net::SSLeay::CTX_new();
        Net::SSLeay::CTX_set_cert_verify_callback($ctx2, \&verify4, 1);

        {
            my $s = $server->connect();

            my $ssl = Net::SSLeay::new($ctx);
            Net::SSLeay::set_fd($ssl, fileno($s));
            Net::SSLeay::connect($ssl);

            Net::SSLeay::ssl_write_all($ssl, $msg);

	    push @results, [Net::SSLeay::shutdown($ssl) >= 0, 'verify: client side ssl shutdown' ];
            shutdown $s, 2;
            close $s;
            Net::SSLeay::free($ssl);

            push @results, [ $verify_cb_1_called == 1, 'verify cb 1 called once' ];
            push @results, [ $verify_cb_2_called == 0, 'verify cb 2 wasn\'t called yet' ];
            push @results, [ $verify_cb_3_called == 0, 'verify cb 3 wasn\'t called yet' ];
        }

        {
            my $s1 = $server->connect();
            my $s2 = $server->connect();
            my $s3 = $server->connect();

            my $ssl1 = Net::SSLeay::new($ctx);
            Net::SSLeay::set_verify($ssl1, &Net::SSLeay::VERIFY_PEER, \&verify2);
            Net::SSLeay::set_fd($ssl1, $s1);

            my $ssl2 = Net::SSLeay::new($ctx);
            Net::SSLeay::set_verify($ssl2, &Net::SSLeay::VERIFY_PEER, \&verify3);
            Net::SSLeay::set_fd($ssl2, $s2);

            my $ssl3 = Net::SSLeay::new($ctx2);
            Net::SSLeay::set_fd($ssl3, $s3);

            Net::SSLeay::connect($ssl1);
            Net::SSLeay::ssl_write_all($ssl1, $msg);
	    push @results, [Net::SSLeay::shutdown($ssl1) >= 0, 'client side ssl1 shutdown' ];
            shutdown $s1, 2;

            Net::SSLeay::connect($ssl2);
            Net::SSLeay::ssl_write_all($ssl2, $msg);
	    push @results, [Net::SSLeay::shutdown($ssl2) >= 0, 'client side ssl2 shutdown' ];
            shutdown $s2, 2;

            Net::SSLeay::connect($ssl3);
            Net::SSLeay::ssl_write_all($ssl3, $msg);
	    push @results, [Net::SSLeay::shutdown($ssl3) >= 0, 'client side ssl3 shutdown' ];
            shutdown $s3, 2;

            close $s1;
            close $s2;
            close $s3;

            Net::SSLeay::free($ssl1);
            Net::SSLeay::free($ssl2);
            Net::SSLeay::free($ssl3);

            push @results, [ $verify_cb_1_called == 1, 'verify cb 1 wasn\'t called again' ];
            push @results, [ $verify_cb_2_called == 1, 'verify cb 2 called once' ];
            push @results, [ $verify_cb_3_called == 1, 'verify cb 3 wasn\'t called yet' ];
        }


        Net::SSLeay::CTX_free($ctx);
        Net::SSLeay::CTX_free($ctx2);
    }

    sub verify {
        my ($ok, $x509_store_ctx) = @_;

        # Skip intermediate certs but propagate possible not ok condition
        my $depth = Net::SSLeay::X509_STORE_CTX_get_error_depth($x509_store_ctx);
        return $ok unless $depth == 0;

        $verify_cb_1_called++;

        my $cert = Net::SSLeay::X509_STORE_CTX_get_current_cert($x509_store_ctx);
        push @results, [ $cert, 'verify cb cert' ];

        my $issuer_name = Net::SSLeay::X509_get_issuer_name( $cert );
        my $issuer  = Net::SSLeay::X509_NAME_oneline( $issuer_name );

        my $subject_name = Net::SSLeay::X509_get_subject_name( $cert );
        my $subject = Net::SSLeay::X509_NAME_oneline( $subject_name );

        my $cn = Net::SSLeay::X509_NAME_get_text_by_NID($subject_name, &Net::SSLeay::NID_commonName);

	my $fingerprint =  Net::SSLeay::X509_get_fingerprint($cert, 'SHA-1');

        push @results, [ $ok == 1, 'verify is ok' ];
        push @results, [ $issuer eq $cert_issuer, 'cert issuer' ];
        push @results, [ $subject eq $cert_name, 'cert subject' ];
        push @results, [ substr($cn, length($cn) - 1, 1) ne "\0", 'tailing 0 character is not returned from get_text_by_NID' ];
        push @results, [ $fingerprint eq $cert_sha1_fp, 'SHA-1 fingerprint' ];

        return 1;
    }

    sub verify2 {
        my ($ok, $x509_store_ctx) = @_;

        # Skip intermediate certs but propagate possible not ok condition
        my $depth = Net::SSLeay::X509_STORE_CTX_get_error_depth($x509_store_ctx);
        return $ok unless $depth == 0;

        $verify_cb_2_called++;
        push @results, [ $ok == 1, 'verify 2 is ok' ];
        return $ok;
    }

    sub verify3 {
        my ($ok, $x509_store_ctx) = @_;

        # Skip intermediate certs but propagate possible not ok condition
        my $depth = Net::SSLeay::X509_STORE_CTX_get_error_depth($x509_store_ctx);
        return $ok unless $depth == 0;

        $verify_cb_3_called++;
        push @results, [ $ok == 1, 'verify 3 is ok' ];
        return $ok;
    }

    sub verify4 {
        my ($cert_store, $userdata) = @_;
        push @results, [$userdata == 1, 'CTX_set_cert_verify_callback'];
        return $userdata;
    }
}

{
    my $s = $server->connect();

    my $ctx = Net::SSLeay::CTX_new();
    my $ssl = Net::SSLeay::new($ctx);

    Net::SSLeay::set_fd($ssl, fileno($s));
    Net::SSLeay::connect($ssl);

    my $cert = Net::SSLeay::get_peer_certificate($ssl);

    my $subject = Net::SSLeay::X509_NAME_oneline(
            Net::SSLeay::X509_get_subject_name($cert)
    );

    my $issuer  = Net::SSLeay::X509_NAME_oneline(
            Net::SSLeay::X509_get_issuer_name($cert)
    );

    push @results, [ $subject eq $cert_name, 'get_peer_certificate subject' ];
    push @results, [ $issuer eq $cert_issuer, 'get_peer_certificate issuer' ];

    my $data = 'a' x 1024 ** 2;
    my $written = Net::SSLeay::ssl_write_all($ssl, \$data);
    push @results, [ $written == length $data, 'ssl_write_all' ];

    push @results, [Net::SSLeay::shutdown($ssl) >= 0, 'client side aaa write ssl shutdown' ];
    shutdown $s, 1;

    my $got = Net::SSLeay::ssl_read_all($ssl);
    push @results, [ $got eq uc($data), 'ssl_read_all' ];

    Net::SSLeay::free($ssl);
    Net::SSLeay::CTX_free($ctx);

    close $s;
}

waitpid $pid, 0;
push @results, [ $? == 0, 'server exited with 0' ];

END {
    Test::More->builder->current_test(87);
    for my $t (@results) {
        ok( $t->[0], $t->[1] );
    }
}

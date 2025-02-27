#!/usr/bin/perl
#
#  Copyright (c) 2011-2017 FastMail Pty Ltd. All rights reserved.
#
#  Redistribution and use in source and binary forms, with or without
#  modification, are permitted provided that the following conditions
#  are met:
#
#  1. Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
#
#  2. Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in
#     the documentation and/or other materials provided with the
#     distribution.
#
#  3. The name "Fastmail Pty Ltd" must not be used to
#     endorse or promote products derived from this software without
#     prior written permission. For permission or any legal
#     details, please contact
#      FastMail Pty Ltd
#      PO Box 234
#      Collins St West 8007
#      Victoria
#      Australia
#
#  4. Redistributions of any form whatsoever must retain the following
#     acknowledgment:
#     "This product includes software developed by Fastmail Pty. Ltd."
#
#  FASTMAIL PTY LTD DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE,
#  INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY  AND FITNESS, IN NO
#  EVENT SHALL OPERA SOFTWARE AUSTRALIA BE LIABLE FOR ANY SPECIAL, INDIRECT
#  OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF
#  USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
#  TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE
#  OF THIS SOFTWARE.
#

package Cassandane::Cyrus::SearchFuzzy;
use strict;
use warnings;
use Cwd qw(abs_path);
use DateTime;
use Data::Dumper;
use File::Temp qw(tempdir);
use File::stat;
use MIME::Base64 qw(encode_base64);
use Encode qw(decode encode);

use lib '.';
use base qw(Cassandane::Cyrus::TestCase);
use Cassandane::Util::Log;

sub new
{

    my ($class, @args) = @_;
    my $config = Cassandane::Config->default()->clone();
    $config->set(
        conversations => 'on',
        httpallowcompress => 'no',
        httpmodules => 'jmap',
    );
    return $class->SUPER::new({
        config => $config,
        jmap => 1,
        services => [ 'imap', 'http' ]
    }, @args);
}

sub set_up
{
    my ($self) = @_;
    $self->SUPER::set_up();

    # This will be "words" if Xapian has a CJK word-tokeniser, "ngrams"
    # if it doesn't, or "none" if it cannot tokenise CJK at all.
    $self->{xapian_cjk_tokens} =
        $self->{instance}->{buildinfo}->get('search', 'xapian_cjk_tokens')
        || "none";

    xlog $self, "Xapian CJK tokeniser '$self->{xapian_cjk_tokens}' detected.\n";

    use experimental 'smartmatch';
    my $skipdiacrit = $self->{instance}->{config}->get('search_skipdiacrit');
    if (not defined $skipdiacrit) {
        $skipdiacrit = 1;
    }
    if ($skipdiacrit ~~ ['no', 'off', 'f', 'false', '0']) {
        $skipdiacrit = 0;
    }
    $self->{skipdiacrit} = $skipdiacrit;

    my $fuzzyalways = $self->{instance}->{config}->get('search_fuzzy_always');
    if ($fuzzyalways ~~ ['yes', 'on', 't', 'true', '1']) {
        $self->{fuzzyalways} = 1;
    } else {
        $self->{fuzzyalways} = 0 ;
    }
}

sub tear_down
{
    my ($self) = @_;
    $self->SUPER::tear_down();
}


sub create_testmessages
{
    my ($self) = @_;

    xlog $self, "Generate test messages.";
    # Some subjects with the same verb word stem
    $self->make_message("I am running") || die;
    $self->make_message("I run") || die;
    $self->make_message("He runs") || die;

    # Some bodies with the same word stems but different senders. We use
    # the "connect" word stem since it it the first example on Xapian's
    # Stemming documentation (https://xapian.org/docs/stemming.html).
    # Mails from foo@example.com...
    my %params;
    %params = (
        from => Cassandane::Address->new(
            localpart => "foo",
            domain => "example.com"
        ),
    );
    $params{'body'} ="He has connections.",
    $self->make_message("1", %params) || die;
    $params{'body'} = "Gonna get myself connected.";
    $self->make_message("2", %params) || die;
    # ...as well as from bar@example.com.
    %params = (
        from => Cassandane::Address->new(
            localpart => "bar",
            domain => "example.com"
        ),
        body => "Einstein's gravitational theory resulted in beautiful relations connecting gravitational phenomena with the geometry of space; this was an exciting idea."
    );
    $self->make_message("3", %params) || die;

    # Create the search database.
    xlog $self, "Run squatter";
    $self->{instance}->run_command({cyrus => 1}, 'squatter');
}

sub get_snippets
{
    # Previous versions of this test module used XSNIPPETS to
    # assert snippets but this command got removed from Cyrus.
    # Use JMAP instead.

    my ($self, $folder, $uids, $filter) = @_;

    my $imap = $self->{store}->get_client();
    my $jmap = $self->{jmap};

    $self->assert_not_null($jmap);

    $imap->select($folder);
    my $res = $imap->fetch($uids, ['emailid']);
    my %emailIdToImapUid = map { $res->{$_}{emailid}[0] => $_ } keys %$res;

    $res = $jmap->CallMethods([
        ['SearchSnippet/get', {
            filter => $filter,
            emailIds => [ keys %emailIdToImapUid ],
        }, 'R1'],
    ]);

    my @snippets;
    foreach (@{$res->[0][1]{list}}) {
        if ($_->{subject}) {
            push(@snippets, [
                0,
                $emailIdToImapUid{$_->{emailId}},
                'SUBJECT',
                $_->{subject},
            ]);
        }
        if ($_->{preview}) {
            push(@snippets, [
                0,
                $emailIdToImapUid{$_->{emailId}},
                'BODY',
                $_->{preview},
            ]);
        }
    }

    return {
        snippets => [ sort { $a->[1] <=> $b->[1] } @snippets ],
    };
}

sub test_copy_messages
    :needs_search_xapian
{
    my ($self) = @_;

    $self->create_testmessages();

    my $talk = $self->{store}->get_client();
    $talk->create("INBOX.foo");
    $talk->select("INBOX");
    $talk->copy("1:*", "INBOX.foo");

    xlog $self, "Run squatter again";
    $self->{instance}->run_command({cyrus => 1}, 'squatter', '-i');
}

sub test_stem_verbs
    :min_version_3_0 :needs_search_xapian :JMAPExtensions
{
    my ($self) = @_;
    $self->create_testmessages();

    my $talk = $self->{store}->get_client();
    $self->assert_not_null($self->{jmap});

    xlog $self, "Select INBOX";
    my $r = $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');
    my $uids = $talk->search('1:*', 'NOT', 'DELETED');

    xlog $self, 'SEARCH for subject "runs"';
    $r = $talk->search('subject', { Quote => "runs" }) || die;
    if ($self->{fuzzyalways}) {
        $self->assert_num_equals(3, scalar @$r);
    } else {
        $self->assert_num_equals(1, scalar @$r);
    }

    xlog $self, 'SEARCH for FUZZY subject "runs"';
    $r = $talk->search('fuzzy', ['subject', { Quote => "runs" }]) || die;
    $self->assert_num_equals(3, scalar @$r);

    xlog $self, 'Get snippets for FUZZY subject "runs"';
    $r = $self->get_snippets('INBOX', $uids, { subject => 'runs' });
    $self->assert_num_equals(3, scalar @{$r->{snippets}});
}

sub test_stem_any
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;
    $self->create_testmessages();

    my $talk = $self->{store}->get_client();

    xlog $self, "Select INBOX";
    $talk->select("INBOX") || die;

    my $r;
    xlog $self, 'SEARCH for body "connection"';
    $r = $talk->search('body', { Quote => "connection" }) || die;
    if ($self->{fuzzyalways})  {
        $self->assert_num_equals(3, scalar @$r);
    } else {
        $self->assert_num_equals(1, scalar @$r);
    }


    xlog $self, "SEARCH for FUZZY body \"connection\"";
    $r = $talk->search(
        "fuzzy", ["body", { Quote => "connection" }],
    ) || die;
    $self->assert_num_equals(3, scalar @$r);
}

sub test_snippet_wildcard
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;

    # Set up Xapian database
    xlog $self, "Generate and index test messages";
    my %params = (
        mime_charset => "utf-8",
    );
    my $subject;
    my $body;

    $subject = "1";
    $body = "Waiter! There's a foo in my soup!";
    $params{body} = $body;
    $self->make_message($subject, %params) || die;

    $subject = "2";
    $body = "Let's foop the loop.";
    $params{body} = $body;
    $self->make_message($subject, %params) || die;

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    my $term = "foo";
    xlog $self, "SEARCH for FUZZY body $term*";
    my $r = $talk->search(
        "fuzzy", ["body", { Quote => "$term*" }],
    ) || die;
    $self->assert_num_equals(2, scalar @$r);
    my $uids = $r;

    xlog $self, "Select INBOX";
    $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');

    xlog $self, "Get snippets for $term";
    $r = $self->get_snippets('INBOX', $uids, { 'text' => "$term*" });
    $self->assert_num_equals(2, scalar @{$r->{snippets}});
}

sub test_mix_fuzzy_and_nonfuzzy
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;
    $self->create_testmessages();
    my $talk = $self->{store}->get_client();

    xlog $self, "Select INBOX";
    $talk->select("INBOX") || die;

    xlog $self, "SEARCH for from \"foo\@example.com\" with FUZZY body \"connection\"";
    my $r = $talk->search(
        "fuzzy", ["body", { Quote => "connection" }],
        "from", { Quote => "foo\@example.com" }
    ) || die;
    $self->assert_num_equals(2, scalar @$r);
}

sub test_weird_crasher
    :Conversations :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;
    return if not $self->{test_fuzzy_search};
    $self->create_testmessages();

    my $talk = $self->{store}->get_client();

    xlog $self, "Select INBOX";
    $talk->select("INBOX") || die;

    xlog $self, "SEARCH for 'A 李 A'";
    my $r = $talk->xconvmultisort( [ qw(reverse arrival) ], [ 'conversations', position => [1,10] ], 'utf-8', 'fuzzy', 'text', { Quote => "A 李 A" });
    $self->assert_not_null($r);
}

sub test_stopwords
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;

    # This test assumes that "the" is a stopword and is configured with
    # the search_stopword_path in cassandane.ini. If the option is not
    # set it tests legacy behaviour.

    my $talk = $self->{store}->get_client();

    # Set up Xapian database
    xlog $self, "Generate and index test messages.";
    my %params = (
        mime_charset => "utf-8",
    );
    my $subject;
    my $body;

    $subject = "1";
    $body = "In my opinion the soup smells tasty";
    $params{body} = $body;
    $self->make_message($subject, %params) || die;

    $subject = "2";
    $body = "The funny thing is that this isn't funny";
    $params{body} = $body;
    $self->make_message($subject, %params) || die;

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    # Connect via IMAP
    xlog $self, "Select INBOX";
    $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');
    my $uids = $talk->search('1:*', 'NOT', 'DELETED');

    my $term;
    my $r;

    # Search for stopword only
    $r = $talk->search(
        "charset", "utf-8", "fuzzy", "text", "the",
    ) || die;
    $self->assert_num_equals(2, scalar @$r);

    # Search for stopword plus significant term
    $r = $talk->search(
        "charset", "utf-8", "fuzzy", "text", "the soup",
    ) || die;
    $self->assert_num_equals(1, scalar @$r);

    $r = $talk->search(
        "charset", "utf-8", "fuzzy", "text", "the", "fuzzy", "text", "soup",
    ) || die;
    $self->assert_num_equals(1, scalar @$r);
}

sub test_normalize_snippets
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;

    # Set up test message with funny characters
use utf8;
    my @terms = ( "gären", "советской", "diĝir", "naïve", "léger" );
no utf8;
    my $body = encode_base64(encode('UTF-8', join(' ', @terms)));
    $body =~ s/\r?\n/\r\n/gs;

    xlog $self, "Generate and index test messages.";
    my %params = (
        mime_charset => "utf-8",
        mime_encoding => 'base64',
        body => $body,
    );
    $self->make_message("1", %params) || die;

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    # Connect to IMAP
    xlog $self, "Select INBOX";
    my $r = $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');
    my $uids = $talk->search('1:*', 'NOT', 'DELETED');

    # Assert that diacritics are matched and returned
    foreach my $term (@terms) {
        $r = $self->get_snippets('INBOX', $uids, { text => $term });
        $self->assert_num_not_equals(index($r->{snippets}[0][3], "<mark>$term</mark>"), -1);
    }

    # Assert that search without diacritics matches
    if ($self->{skipdiacrit}) {
        my $term = "naive";
        xlog $self, "Get snippets for FUZZY text \"$term\"";
        $r = $self->get_snippets('INBOX', $uids, { 'text' => $term });
use utf8;
        $self->assert_num_not_equals(index($r->{snippets}[0][3], "<mark>naïve</mark>"), -1);
no utf8;
    }

}

sub test_skipdiacrit
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;

    # Set up test messages
    my $body = "Die Trauben gären.";
    xlog $self, "Generate and index test messages.";
    my %params = (
        mime_charset => "utf-8",
        body => $body
    );
    $self->make_message("1", %params) || die;
    $body = "Gemüse schonend garen.";
    %params = (
        mime_charset => "utf-8",
        body => $body
    );
    $self->make_message("2", %params) || die;

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    # Connect to IMAP
    xlog $self, "Select INBOX";
    my $r = $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');
    my $uids = $talk->search('1:*', 'NOT', 'DELETED');

    xlog $self, 'Search for "garen"';
    $r = $talk->search(
        "charset", "utf-8", "fuzzy", ["text", { Quote => "garen" }],
    ) || die;
    if ($self->{skipdiacrit}) {
        $self->assert_num_equals(2, scalar @$r);
    } else {
        $self->assert_num_equals(1, scalar @$r);
    }

    xlog $self, 'Search for "gären"';
    $r = $talk->search(
        "charset", "utf-8", "fuzzy", ["text", { Quote => "gären" }],
    ) || die;
    if ($self->{skipdiacrit}) {
        $self->assert_num_equals(2, scalar @$r);
    } else {
        $self->assert_num_equals(1, scalar @$r);
    }
}

sub test_snippets_termcover
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;

    my $body =
    "The 'charset' portion of an 'encoded-word' specifies the character ".
    "set associated with the unencoded text.  A 'charset' can be any of ".
    "the character set names allowed in an MIME \"charset\" parameter of a ".
    "\"text/plain\" body part, or any character set name registered with ".
    "IANA for use with the MIME text/plain content-type. ".
    "".
    # Attempt to trick the snippet generator into picking the next two lines
    "Here is a line with favourite but not without that other search word ".
    "Here is another line with a favourite word but not the other one ".
    "".
    "Some character sets use code-switching techniques to switch between ".
    "\"ASCII mode\" and other modes.  If unencoded text in an 'encoded-word' ".
    "contains a sequence which causes the charset interpreter to switch ".
    "out of ASCII mode, it MUST contain additional control codes such that ".
    "ASCII mode is again selected at the end of the 'encoded-word'.  (This ".
    "rule applies separately to each 'encoded-word', including adjacent ".
    "encoded-word's within a single header field.) ".
    "When there is a possibility of using more than one character set to ".
    "represent the text in an 'encoded-word', and in the absence of ".
    "private agreements between sender and recipients of a message, it is ".
    "recommended that members of the ISO-8859-* series be used in ".
    "preference to other character sets.".
    "".
    # This is the line we want to get as a snippet
    "I don't have a favourite cereal. My favourite breakfast is oat meal.";

    xlog $self, "Generate and index test messages.";
    my %params = (
        mime_charset => "utf-8",
        body => $body
    );
    $self->make_message("1", %params) || die;

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    # Connect to IMAP
    xlog $self, "Select INBOX";
    my $r = $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');
    my $uids = $talk->search('1:*', 'NOT', 'DELETED');
    my $want = "<mark>favourite</mark> <mark>cereal</mark>";

    $r = $self->get_snippets('INBOX', $uids, {
        operator => 'AND',
        conditions => [{
            text => 'favourite',
        }, {
           text => 'cereal',
        }, {
           text => '"bogus gnarly"'
        }],
    });
    $self->assert_num_not_equals(-1, index($r->{snippets}[0][3], $want));

    $r = $self->get_snippets('INBOX', $uids, {
        text => 'favourite cereal',
    });
    $self->assert_num_not_equals(-1, index($r->{snippets}[0][3], $want));
}

sub test_cjk_words
    :min_version_3_0 :needs_search_xapian
    :needs_search_xapian_cjk_tokens(words)
{
    my ($self) = @_;

    xlog $self, "Generate and index test messages.";

use utf8;
    my $body = "明末時已經有香港地方的概念";
no utf8;
    $body = encode_base64(encode('UTF-8', $body));
    $body =~ s/\r?\n/\r\n/gs;
    my %params = (
        mime_charset => "utf-8",
        mime_encoding => 'base64',
        body => $body,
    );
    $self->make_message("1", %params) || die;

    # Splits into the words: "み, 円, 月額, 申込
use utf8;
    $body = "申込み！月額円";
no utf8;
    $body = encode_base64(encode('UTF-8', $body));
    $body =~ s/\r?\n/\r\n/gs;
    %params = (
        mime_charset => "utf-8",
        mime_encoding => 'base64',
        body => $body,
    );
    $self->make_message("2", %params) || die;

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    # Connect to IMAP
    xlog $self, "Select INBOX";
    my $r = $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');
    my $uids = $talk->search('1:*', 'NOT', 'DELETED');

    my $term;
    # Search for a two-character CJK word
use utf8;
    $term = "已經";
no utf8;
    xlog $self, "Get snippets for FUZZY text \"$term\"";
    $r = $self->get_snippets('INBOX', $uids, { text => $term });
    $self->assert_num_not_equals(index($r->{snippets}[0][3], "<mark>$term</mark>"), -1);

    # Search for the CJK words 明末 and 時, note that the
    # word order is reversed to the original message
use utf8;
    $term = "時明末";
no utf8;
    xlog $self, "Get snippets for FUZZY text \"$term\"";
    $r = $self->get_snippets('INBOX', $uids, { text => $term });
    $self->assert_num_equals(scalar @{$r->{snippets}}, 1);

    # Search for the partial CJK word 月
use utf8;
    $term = "月";
no utf8;
    xlog $self, "Get snippets for FUZZY text \"$term\"";
    $r = $self->get_snippets('INBOX', $uids, { text => $term });
    $self->assert_num_equals(scalar @{$r->{snippets}}, 0);

    # Search for the interleaved, partial CJK word 額申
use utf8;
    $term = "額申";
no utf8;
    xlog $self, "Get snippets for FUZZY text \"$term\"";
    $r = $self->get_snippets('INBOX', $uids, { text => $term });
    $self->assert_num_equals(scalar @{$r->{snippets}}, 0);

    # Search for three of four words: "み, 月額, 申込",
    # in different order than the original.
use utf8;
    $term = "月額み申込";
no utf8;
    xlog $self, "Get snippets for FUZZY text \"$term\"";
    $r = $self->get_snippets('INBOX', $uids, { text => $term });
    $self->assert_num_equals(scalar @{$r->{snippets}}, 1);
}

sub test_subject_isutf8
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;

    xlog $self, "Generate and index test messages.";
    # that's: "nuff réunion critères duff"
    my $subject = "=?utf-8?q?nuff_r=C3=A9union_crit=C3=A8res_duff?=";
    my $body = "empty";
    my %params = (
        mime_charset => "utf-8",
        body => $body
    );
    $self->make_message($subject, %params) || die;
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    # Connect to IMAP
    xlog $self, "Select INBOX";
    my $r = $talk->select("INBOX") || die;

    # Search subject without accents
    # my $term = "réunion critères";
    my %searches;

    if ($self->{skipdiacrit}) {
        # Diacritics are stripped before indexing and search. That's a sane
        # choice as long as there is no language-specific stemming applied
        # during indexing and search.
        %searches = (
            "reunion criteres" => 1,
            "réunion critères" => 1,
            "reunion critères" => 1,
            "réunion criter" => 1,
            "réunion crit" => 0,
            "union critères" => 0,
        );
        my $term = "naive";
    } else {
        # Diacritics are not stripped from search. This currently is very
        # restrictive: until Cyrus can stem by language, this is basically
        # a whole-word match.
        %searches = (
            "reunion criteres" => 0,
            "réunion critères" => 1,
            "reunion critères" => 0,
            "réunion criter" => 0,
            "réunion crit" => 0,
            "union critères" => 0,
        );
    }

    while (my($term, $expectedCnt) = each %searches) {
        xlog $self, "SEARCH for FUZZY text \"$term\"";
        $r = $talk->search(
            "charset", "utf-8", "fuzzy", ["text", { Quote => $term }],
        ) || die;
        $self->assert_num_equals($expectedCnt, scalar @$r);
    }

}

sub test_noindex_multipartheaders
    :needs_search_xapian
{
    my ($self) = @_;

    my $talk = $self->{store}->get_client();

    my $body = ""
    . "--boundary\r\n"
    . "Content-Type: text/plain\r\n"
    . "\r\n"
    . "body"
    . "\r\n"
    . "--boundary\r\n"
    . "Content-Type: application/octet-stream\r\n"
    . "Content-Transfer-Encoding: base64\r\n"
    . "\r\n"
    . "SGVsbG8sIFdvcmxkIQ=="
    . "\r\n"
    . "--boundary\r\n"
    . "Content-Type: message/rfc822\r\n"
    . "\r\n"
    . "Return-Path: <bla\@local>\r\n"
    . "Mime-Version: 1.0\r\n"
    . "Content-Type: text/plain"
    . "Content-Transfer-Encoding: 7bit\r\n"
    . "Subject: baz\r\n"
    . "From: blu\@local\r\n"
    . "Message-ID: <fake.12123239947.6507\@local>\r\n"
    . "Date: Wed, 06 Oct 2016 14:59:07 +1100\r\n"
    . "To: Test User <test\@local>\r\n"
    . "\r\n"
    . "embedded"
    . "\r\n"
    . "--boundary--\r\n";

    $self->make_message("foo",
        mime_type => "multipart/mixed",
        mime_boundary => "boundary",
        body => $body
    );

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $r;

    $r = $talk->search(
        "header", "Content-Type", { Quote => "multipart/mixed" }
    ) || die;
    $self->assert_num_equals(1, scalar @$r);

    # Don't index the headers of multiparts or embedded RFC822s
    $r = $talk->search(
        "header", "Content-Type", { Quote => "text/plain" }
    ) || die;
    $self->assert_num_equals(0, scalar @$r);
    $r = $talk->search(
        "fuzzy", "body", { Quote => "text/plain" }
    ) || die;
    $self->assert_num_equals(0, scalar @$r);
    $r = $talk->search(
        "fuzzy", "text", { Quote => "content" }
    ) || die;
    $self->assert_num_equals(0, scalar @$r);

    # But index the body of an embedded RFC822
    $r = $talk->search(
        "fuzzy", "body", { Quote => "embedded" }
    ) || die;
    $self->assert_num_equals(1, scalar @$r);
}

sub test_xattachmentname
    :needs_search_xapian
{
    my ($self) = @_;

    my $talk = $self->{store}->get_client();

    my $body = ""
    . "--boundary\r\n"
    . "Content-Type: text/plain\r\n"
    . "\r\n"
    . "body"
    . "\r\n"
    . "--boundary\r\n"
    . "Content-Type: application/x-excel; name=\"blah\"\r\n"
    . "Content-Transfer-Encoding: base64\r\n"
    . "Content-Disposition: attachment; filename=\"stuff.xls\"\r\n"
    . "\r\n"
    . "SGVsbG8sIFdvcmxkIQ=="
    . "\r\n"
    . "--boundary--\r\n";

    $self->make_message("foo",
        mime_type => "multipart/mixed",
        mime_boundary => "boundary",
        body => $body
    );

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $r;

    $r = $talk->search(
        "fuzzy", "xattachmentname", { Quote => "stuff" }
    ) || die;
    $self->assert_num_equals(1, scalar @$r);

    $r = $talk->search(
        "fuzzy", "xattachmentname", { Quote => "nope" }
    ) || die;
    $self->assert_num_equals(0, scalar @$r);

    $r = $talk->search(
        "fuzzy", "text", { Quote => "stuff.xls" }
    ) || die;
    $self->assert_num_equals(1, scalar @$r);

    $r = $talk->search(
        "fuzzy", "xattachmentname", { Quote => "blah" },
    ) || die;
    $self->assert_num_equals(1, scalar @$r);
}


sub test_snippets_escapehtml
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;

    xlog $self, "Generate and index test messages.";
    $self->make_message("Test1 subject with an unescaped & in it",
        mime_charset => "utf-8",
        mime_type => "text/html",
        body => "Test1 body with the same <b>tag</b> as snippets"
    ) || die;

    $self->make_message("Test2 subject with a <tag> in it",
        mime_charset => "utf-8",
        mime_type => "text/plain",
        body => "Test2 body with a <tag/>, although it's plain text",
    ) || die;

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    # Connect to IMAP
    xlog $self, "Select INBOX";
    my $r = $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');
    my $uids = $talk->search('1:*', 'NOT', 'DELETED');
    my %m;

    $r = $self->get_snippets('INBOX', $uids, { 'text' => 'test1' });
    %m = map { lc($_->[2]) => $_->[3] } @{ $r->{snippets} };
    $self->assert_str_equals("<mark>Test1</mark> body with the same tag as snippets", $m{body});
    $self->assert_str_equals("<mark>Test1</mark> subject with an unescaped &amp; in it", $m{subject});

    $r = $self->get_snippets('INBOX', $uids, { 'text' => 'test2' });
    %m = map { lc($_->[2]) => $_->[3] } @{ $r->{snippets} };
    $self->assert_str_equals("<mark>Test2</mark> body with a &lt;tag/&gt;, although it's plain text", $m{body});
    $self->assert_str_equals("<mark>Test2</mark> subject with a &lt;tag&gt; in it", $m{subject});
}

sub test_search_exactmatch
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;

    xlog $self, "Generate and index test messages.";
    $self->make_message("test1",
        body => "Test1 body with some long text and there is even more ".
                "and more and more and more and more and more and more ".
                "and more and more and some text and more and more and ".
                "and more and more and more and more and more and more ".
                "and almost at the end some other text that is a match ",
    ) || die;
    $self->make_message("test2",
        body => "Test2 body with some other text",
    ) || die;

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    xlog $self, "Select INBOX";
    my $r = $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');
    my $uids = $talk->search('1:*', 'NOT', 'DELETED');

    xlog $self, 'SEARCH for FUZZY exact match';
    my $query = '"some text"';
    $uids = $talk->search('fuzzy', 'body', $query) || die;
    $self->assert_num_equals(1, scalar @$uids);

    my %m;
    $r = $self->get_snippets('INBOX', $uids, { body => $query });
    %m = map { lc($_->[2]) => $_->[3] } @{ $r->{snippets} };
    $self->assert(index($m{body}, "<mark>some text</mark>") != -1);
    $self->assert(index($m{body}, "<mark>some</mark> long <mark>text</mark>") == -1);
}

sub test_search_subjectsnippet
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;

    xlog $self, "Generate and index test messages.";
    $self->make_message("[plumbing] Re: log server v0 live",
        body => "Test1 body with some long text and there is even more ".
                "and more and more and more and more and more and more ".
                "and more and more and some text and more and more and ".
                "and more and more and more and more and more and more ".
                "and almost at the end some other text that is a match ",
    ) || die;
    $self->make_message("test2",
        body => "Test2 body with some other text",
    ) || die;

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    xlog $self, "Select INBOX";
    my $r = $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');
    my $uids = $talk->search('1:*', 'NOT', 'DELETED');

    xlog $self, 'SEARCH for FUZZY snippets';
    my $query = 'servers';
    $uids = $talk->search('fuzzy', 'text', $query) || die;
    $self->assert_num_equals(1, scalar @$uids);

    my %m;
    $r = $self->get_snippets('INBOX', $uids, { text => $query });
    %m = map { lc($_->[2]) => $_->[3] } @{ $r->{snippets} };
    $self->assert_matches(qr/^\[plumbing\]/, $m{subject});
}

sub test_audit_unindexed
    :min_version_3_1 :needs_component_jmap
{
    # This test does some sneaky things to cyrus.indexed.db to force squatter
    # report audit errors. It assumes a specific format for cyrus.indexed.db
    # and Cyrus to preserve UIDVALDITY across two consecutive APPENDs.
    # As such, it's likely to break for internal changes.

    my ($self) = @_;

    my $talk = $self->{store}->get_client();

    my $basedir = $self->{instance}->{basedir};
    my $outfile = "$basedir/audit.tmp";

    *_readfile = sub {
        open FH, '<', $outfile
            or die "Cannot open $outfile for reading: $!";
        my @entries = readline(FH);
        close FH;
        return @entries;
    };

    xlog $self, "Create message UID 1 and index it in Xapian and cyrus.indexed.db.";
    $self->make_message() || die;
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    xlog $self, "Create message UID 2 but *don't* index it.";
    $self->make_message() || die;

    my $data = $self->{instance}->run_mbpath(-u => 'cassandane');
    my $xapdir = $data->{xapian}{t1};

    xlog $self, "Read current cyrus.indexed.db.";
    my ($key, $val);
    my $result = $self->{instance}->run_dbcommand_cb(sub {
      my ($k, $v) = @_;
      return if $k =~ m/\*V\*/;
      $self->assert_null($key);
      ($key, $val) = ($k, $v);
    }, "$xapdir/xapian/cyrus.indexed.db", "twoskip", ['SHOW']);
    $self->assert_str_equals('ok', $result);
    $self->assert_not_null($key);
    $self->assert_not_null($val);

    xlog $self, "Add UID 2 to sequence set in cyrus.indexed.db";
    $self->{instance}->run_dbcommand("$xapdir/xapian/cyrus.indexed.db", "twoskip", ['SET', $key, $val . ':2']);

    xlog $self, "Run squatter audit";
    $result = $self->{instance}->run_command(
        {
            cyrus => 1,
            redirects => { stdout => $outfile },
        },
        'squatter', '-A'
    );
    my @audits = _readfile();
    $self->assert_num_equals(1, scalar @audits);
    $self->assert_str_equals("Unindexed message(s) in user.cassandane: 2 \n", $audits[0]);
}

sub test_search_omit_html
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;

    xlog $self, "Generate and index test messages.";
    $self->make_message("toplevel",
        mime_type => "text/html",
        body => "<html><body><div>hello</div></body></html>"
    ) || die;

    $self->make_message("embedded",
        mime_type => "multipart/related",
        mime_boundary => "boundary_1",
        body => ""
          . "\r\n--boundary_1\r\n"
          . "Content-Type: text/plain\r\n"
          . "\r\n"
          . "txt"
          . "\r\n--boundary_1\r\n"
          . "Content-Type: text/html\r\n"
          . "\r\n"
          . "<html><body><div>world</div></body></html>"
          . "\r\n--boundary_1--\r\n"
    ) || die;

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    my $r = $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');
    my $uids = $talk->search('1:*', 'NOT', 'DELETED');

    $uids = $talk->search('fuzzy', 'body', 'div') || die;
    $self->assert_num_equals(0, scalar @$uids);

    $uids = $talk->search('fuzzy', 'body', 'hello') || die;
    $self->assert_num_equals(1, scalar @$uids);

    $uids = $talk->search('fuzzy', 'body', 'world') || die;
    $self->assert_num_equals(1, scalar @$uids);
}

sub test_search_omit_ical
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;

    xlog $self, "Generate and index test messages.";

    $self->make_message("test",
        mime_type => "multipart/related",
        mime_boundary => "boundary_1",
        body => ""
          . "\r\n--boundary_1\r\n"
          . "Content-Type: text/plain\r\n"
          . "\r\n"
          . "txt body"
          . "\r\n--boundary_1\r\n"
          . "Content-Type: text/calendar;charset=utf-8\r\n"
          . "Content-Transfer-Encoding: quoted-printable\r\n"
          . "\r\n"
          . "BEGIN:VCALENDAR\r\n"
          . "VERSION:2.0\r\n"
          . "PRODID:-//CyrusIMAP.org/Cyrus 3.1.3-606//EN\r\n"
          . "CALSCALE:GREGORIAN\r\n"
          . "BEGIN:VTIMEZONE\r\n"
          . "TZID:Europe/Vienna\r\n"
          . "BEGIN:STANDARD\r\n"
          . "DTSTART:19700101T000000\r\n"
          . "RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10\r\n"
          . "TZOFFSETFROM:+0200\r\n"
          . "TZOFFSETTO:+0100\r\n"
          . "END:STANDARD\r\n"
          . "BEGIN:DAYLIGHT\r\n"
          . "DTSTART:19700101T000000\r\n"
          . "RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=3\r\n"
          . "TZOFFSETFROM:+0100\r\n"
          . "TZOFFSETTO:+0200\r\n"
          . "END:DAYLIGHT\r\n"
          . "END:VTIMEZONE\r\n"
          . "BEGIN:VEVENT\r\n"
          . "SUMMARY:icalsummary\r\n"
          . "DESCRIPTION:icaldesc\r\n"
          . "LOCATION:icallocation\r\n"
          . "CREATED:20180518T090306Z\r\n"
          . "DTEND;TZID=Europe/Vienna:20180518T100000\r\n"
          . "DTSTAMP:20180518T090306Z\r\n"
          . "DTSTART;TZID=Europe/Vienna:20180518T090000\r\n"
          . "LAST-MODIFIED:20180518T090306Z\r\n"
          . "RRULE:FREQ=DAILY\r\n"
          . "SEQUENCE:1\r\n"
          . "SUMMARY:K=C3=A4se\r\n"
          . "TRANSP:OPAQUE\r\n"
          . "UID:1234567890\r\n"
          . "END:VEVENT\r\n"
          . "END:VCALENDAR\r\n"
          . "\r\n--boundary_1--\r\n"
    ) || die;

    $self->make_message("top",
        mime_type => "text/calendar",
        body => ""
          . "BEGIN:VCALENDAR\r\n"
          . "VERSION:2.0\r\n"
          . "PRODID:-//CyrusIMAP.org/Cyrus 3.1.3-606//EN\r\n"
          . "CALSCALE:GREGORIAN\r\n"
          . "BEGIN:VTIMEZONE\r\n"
          . "TZID:Europe/Vienna\r\n"
          . "BEGIN:STANDARD\r\n"
          . "DTSTART:19700101T000000\r\n"
          . "RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10\r\n"
          . "TZOFFSETFROM:+0200\r\n"
          . "TZOFFSETTO:+0100\r\n"
          . "END:STANDARD\r\n"
          . "BEGIN:DAYLIGHT\r\n"
          . "DTSTART:19700101T000000\r\n"
          . "RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=3\r\n"
          . "TZOFFSETFROM:+0100\r\n"
          . "TZOFFSETTO:+0200\r\n"
          . "END:DAYLIGHT\r\n"
          . "END:VTIMEZONE\r\n"
          . "BEGIN:VEVENT\r\n"
          . "SUMMARY:icalsummary\r\n"
          . "DESCRIPTION:icaldesc\r\n"
          . "LOCATION:icallocation\r\n"
          . "CREATED:20180518T090306Z\r\n"
          . "DTEND;TZID=Europe/Vienna:20180518T100000\r\n"
          . "DTSTAMP:20180518T090306Z\r\n"
          . "DTSTART;TZID=Europe/Vienna:20180518T090000\r\n"
          . "LAST-MODIFIED:20180518T090306Z\r\n"
          . "RRULE:FREQ=DAILY\r\n"
          . "SEQUENCE:1\r\n"
          . "TRANSP:OPAQUE\r\n"
          . "UID:1234567890\r\n"
          . "END:VEVENT\r\n"
          . "END:VCALENDAR\r\n"
    ) || die;

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    my $r = $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');
    my $uids = $talk->search('1:*', 'NOT', 'DELETED');

    $uids = $talk->search('fuzzy', 'text', 'rrule') || die;
    $self->assert_num_equals(0, scalar @$uids);

    $uids = $talk->search('fuzzy', 'subject', 'icalsummary') || die;
    $self->assert_num_equals(2, scalar @$uids);

    $uids = $talk->search('fuzzy', 'text', 'icaldesc') || die;
    $self->assert_num_equals(2, scalar @$uids);

    $uids = $talk->search('fuzzy', 'text', 'icallocation') || die;
    $self->assert_num_equals(2, scalar @$uids);
}

sub test_search_omit_vcard
    :min_version_3_9 :needs_search_xapian
{
    my ($self) = @_;

    xlog $self, "Generate and index test messages.";

    $self->make_message("test",
        mime_type => "multipart/related",
        mime_boundary => "boundary_1",
        body => ""
          . "\r\n--boundary_1\r\n"
          . "Content-Type: text/plain\r\n"
          . "\r\n"
          . "txt body"
          . "\r\n--boundary_1\r\n"
          . "Content-Type: text/vcard;charset=utf-8\r\n"
          . "Content-Transfer-Encoding: quoted-printable\r\n"
          . "\r\n"
          . "BEGIN:VCARD\r\n"
          . "VERSION:3.0\r\n"
          . "UID:1234567890\r\n"
          . "BDAY:1944-06-07\r\n"
          . "N:Gump;Forrest;;Mr.\r\n"
          . "FN:Forrest Gump\r\n"
          . "ORG;PROP-ID=O1:Bubba Gump Shrimp Co.\r\n"
          . "TITLE;PROP-ID=T1:Shrimp Man\r\n"
          . "PHOTO;PROP-ID=P1;ENCODING=b;TYPE=JPEG:c29tZSBwaG90bw==\r\n"
          . "foo.ADR;PROP-ID=A1:;;1501 Broadway;New York;NY;10036;USA\r\n"
          . "foo.GEO:40.7571383482188;-73.98695548990568\r\n"
          . "foo.TZ:-05:00\r\n"
          . "EMAIL;TYPE=PREF:bgump\@example.com\r\n"
          . "X-SOCIAL-PROFILE:https://example.com/\@bubba"
          . "REV:2008-04-24T19:52:43Z\r\n"
          . "END:VCARD\r\n"
          . "\r\n--boundary_1--\r\n"
    ) || die;

    $self->make_message("top",
        mime_type => "text/vcard",
        body => ""
          . "BEGIN:VCARD\r\n"
          . "VERSION:3.0\r\n"
          . "UID:1234567890\r\n"
          . "BDAY:1944-06-07\r\n"
          . "N:Gump;Forrest;;Mr.\r\n"
          . "FN:Forrest Gump\r\n"
          . "ORG;PROP-ID=O1:Bubba Gump Shrimp Co.\r\n"
          . "TITLE;PROP-ID=T1:Shrimp Man\r\n"
          . "PHOTO;PROP-ID=P1;ENCODING=b;TYPE=JPEG:c29tZSBwaG90bw==\r\n"
          . "foo.ADR;PROP-ID=A1:;;1501 Broadway;New York;NY;10036;USA\r\n"
          . "foo.GEO:40.7571383482188;-73.98695548990568\r\n"
          . "foo.TZ:-05:00\r\n"
          . "EMAIL;TYPE=PREF:bgump\@example.com\r\n"
          . "X-SOCIAL-PROFILE:https://example.com/\@bubba"
          . "REV:2008-04-24T19:52:43Z\r\n"
          . "END:VCARD\r\n"
    ) || die;

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    my $r = $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');
    my $uids = $talk->search('1:*', 'NOT', 'DELETED');

    $uids = $talk->search('fuzzy', 'text', '1944') || die;
    $self->assert_num_equals(0, scalar @$uids);

    $uids = $talk->search('fuzzy', 'text', 'Forrest') || die;
    $self->assert_num_equals(2, scalar @$uids);

    $uids = $talk->search('fuzzy', 'text', 'Mr.') || die;
    $self->assert_num_equals(2, scalar @$uids);

    $uids = $talk->search('fuzzy', 'text', 'Shrimp') || die;
    $self->assert_num_equals(2, scalar @$uids);

    $uids = $talk->search('fuzzy', 'text', 'example') || die;
    $self->assert_num_equals(2, scalar @$uids);

    $uids = $talk->search('fuzzy', 'text', 'https') || die;
    $self->assert_num_equals(2, scalar @$uids);
}

sub test_xapian_index_partid
    :min_version_3_0 :needs_search_xapian :needs_component_jmap
{
    my ($self) = @_;

    # UID 1: match
    $self->make_message("xtext", body => "xbody",
        from => Cassandane::Address->new(
            localpart => "xfrom",
            domain => "example.com"
        )
    ) || die;

    # UID 2: no match
    $self->make_message("xtext", body => "xtext",
        from => Cassandane::Address->new(
            localpart => "xfrom",
            domain => "example.com"
        )
    ) || die;

    # UID 3: no match
    $self->make_message("xbody", body => "xtext",
        from => Cassandane::Address->new(
            localpart => "xfrom",
            domain => "example.com"
        )
    ) || die;

    # UID 4: match
    $self->make_message("nomatch", body => "xbody xtext",
        from => Cassandane::Address->new(
            localpart => "xfrom",
            domain => "example.com"
        )
    ) || die;

    # UID 5: no match
    $self->make_message("xtext", body => "xbody xtext",
        from => Cassandane::Address->new(
            localpart => "nomatch",
            domain => "example.com"
        )
    ) || die;


    $self->{instance}->run_command({cyrus => 1}, 'squatter', '-v');

    my $talk = $self->{store}->get_client();
    $talk->select("INBOX") || die;
    my $uids = $talk->search('fuzzy', 'from', 'xfrom',
                             'fuzzy', 'body', 'xbody',
                             'fuzzy', 'text', 'xtext') || die;
    $self->assert_num_equals(2, scalar @$uids);
    $self->assert_num_equals(1, @$uids[0]);
    $self->assert_num_equals(4, @$uids[1]);
}

sub test_detect_language
    :min_version_3_2 :needs_search_xapian :needs_dependency_cld2 :SearchLanguage
{
    my ($self) = @_;

    $self->make_message("german",
        mime_type => 'text/plain',
        mime_charset => 'utf-8',
        mime_encoding => 'quoted-printable',
        body => ''
        . "Der Ballon besa=C3=9F eine gewaltige Gr=C3=B6=C3=9Fe, er trug einen Korb, g=\r\n"
        . "ro=C3=9F und ger=C3=A4umig und offenbar f=C3=BCr einen l=C3=A4ngeren Aufenthalt\r\n"
        . "hergeric=htet. Die zwei M=C3=A4nner, welche sich darin befanden, schienen\r\n"
        . "erfahrene Luftschiff=er zu sein, das sah man schon daraus, wie ruhig sie trotz\r\n"
        . "der ungeheuren H=C3=B6he atmeten."
    );

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    my $uids = $talk->search('fuzzy', 'body', 'atmet');
    $self->assert_deep_equals([1], $uids);

    my $r = $talk->select("INBOX") || die;
    $r = $self->get_snippets('INBOX', $uids, { body => 'atmet' });
use utf8;
    $self->assert_num_not_equals(-1, index($r->{snippets}[0][3], ' Höhe <mark>atmeten</mark>.'));
no utf8;
}

sub test_detect_language_subject
    :min_version_3_2 :needs_search_xapian :needs_dependency_cld2 :SearchLanguage
{
    my ($self) = @_;

    my $body = ""
    . "--boundary\r\n"
    . "Content-Type: text/plain;charset=utf-8\r\n"
    . "Content-Transfer-Encoding: quoted-printable\r\n"
    . "\r\n"
    . "Hoch oben in den L=C3=BCften =C3=BCber den reichgesegneten Landschaften des\r\n"
    . "s=C3=BCdlichen Frankreichs schwebte eine gewaltige dunkle Kugel.\r\n"
    . "\r\n"
    . "Ein Luftballon war es, der, in der Nacht aufgefahren, eine lange\r\n"
    . "Dauerfahrt antreten wollte.\r\n"
    . "\r\n"
    . "--boundary\r\n"
    . "Content-Type: text/plain;charset=utf-8\r\n"
    . "Content-Transfer-Encoding: quoted-printable\r\n"
    . "\r\n"
    . "The Bellman, who was almost morbidly sensitive about appearances, used\r\n"
    . "to have the bowsprit unshipped once or twice a week to be revarnished,\r\n"
    . "and it more than once happened, when the time came for replacing it,\r\n"
    . "that no one on board could remember which end of the ship it belonged to.\r\n"
    . "\r\n"
    . "--boundary\r\n"
    . "Content-Type: text/plain;charset=utf-8\r\n"
    . "Content-Transfer-Encoding: quoted-printable\r\n"
    . "\r\n"
    . "Verri=C3=A8res est abrit=C3=A9e du c=C3=B4t=C3=A9 du nord par une haute mon=\r\n"
    . "tagne, c'est une\r\n"
    . "des branches du Jura. Les cimes bris=C3=A9es du Verra se couvrent de neige\r\n"
    . "d=C3=A8s les premiers froids d'octobre. Un torrent, qui se pr=C3=A9cipite d=\r\n"
    . "e la\r\n"
    . "montagne, traverse Verri=C3=A8res avant de se jeter dans le Doubs et donne =\r\n"
    . "le\r\n"
    . "mouvement =C3=A0 un grand nombre de scies =C3=A0 bois; c'est une industrie =\r\n"
    . "--boundary--\r\n";

    $self->make_message("A subject with the German word Landschaften",
        mime_type => "multipart/mixed",
        mime_boundary => "boundary",
        body => $body
    );

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    my $uids = $talk->search('fuzzy', 'subject', 'Landschaft');
    $self->assert_deep_equals([1], $uids);

    my $r = $talk->select("INBOX") || die;
    $r = $self->get_snippets('INBOX', $uids, { subject => 'Landschaft' });
    $self->assert_str_equals(
        'A subject with the German word <mark>Landschaften</mark>',
        $r->{snippets}[0][3]
    );
}

sub test_subject_and_body_match
    :min_version_3_0 :needs_search_xapian :needs_dependency_cld2
{
    my ($self) = @_;

    $self->make_message('fwd subject', body => 'a schenectady body');

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    my $uids = $talk->search('fuzzy', 'text', 'fwd', 'text', 'schenectady');
    $self->assert_deep_equals([1], $uids);
}

sub test_not_match
    :min_version_3_0 :needs_search_xapian :needs_dependency_cld2
{
    my ($self) = @_;
    my $imap = $self->{store}->get_client();
    my $store = $self->{store};

    $imap->create("INBOX.A") or die;
    $store->set_folder("INBOX.A");
    $self->make_message('fwd subject', body => 'a schenectady body');
    $self->make_message('chad subject', body => 'a futz body');

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();
    $talk->select("INBOX.A");
    my $uids = $talk->search('fuzzy', 'not', 'text', 'schenectady');
    $self->assert_deep_equals([2], $uids);
}

sub test_striphtml_alternative
    :min_version_3_3 :needs_search_xapian
{
    my ($self) = @_;
    my $talk = $self->{store}->get_client();

    xlog "Index message with both html and plain text part";
    $self->make_message("test",
        mime_type => "multipart/alternative",
        mime_boundary => "boundary_1",
        body => ""
          . "\r\n--boundary_1\r\n"
          . "Content-Type: text/plain; charset=\"UTF-8\"\r\n"
          . "\r\n"
          . "<div>This is a plain text body with <b>html</b>.</div>\r\n"
          . "\r\n--boundary_1\r\n"
          . "Content-Type: text/html; charset=\"UTF-8\"\r\n"
          . "\r\n"
          . "<div>This is an html body.</div>\r\n"
          . "\r\n--boundary_1--\r\n"
    ) || die;
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    xlog "Assert that HTML in plain text is stripped";
    my $uids = $talk->search('fuzzy', 'body', 'html') || die;
    $self->assert_deep_equals([1], $uids);

    $uids = $talk->search('fuzzy', 'body', 'div') || die;
    $self->assert_deep_equals([], $uids);
}

sub test_html_only
    :min_version_3_3 :needs_search_xapian
{
    my ($self) = @_;
    my $talk = $self->{store}->get_client();

    xlog "Index message with both html and plain text part";
    $self->make_message("test",
        mime_type => "text/html",
        body => ""
          . "<html xmlns:o=\"urn:schemas-microsoft-com:office:office\">\r\n"
          . "<div>This is an html <o:p>LL123</o:p> <h11>xyzzy</h11> body.</div>\r\n"
          . "</html"

    ) || die;
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    xlog "Assert that HTML in plain text is stripped";
    my $uids = $talk->search('fuzzy', 'body', 'html') || die;
    $self->assert_deep_equals([1], $uids);

    $uids = $talk->search('fuzzy', 'body', 'div') || die;
    $self->assert_deep_equals([], $uids);

    # make sure the "p" doesn't leak into a token
    $uids = $talk->search('fuzzy', 'body', 'LL123p') || die;
    $self->assert_deep_equals([], $uids);

    # make sure the real token gets indexed
    $uids = $talk->search('fuzzy', 'body', 'LL123') || die;
    $self->assert_deep_equals([1], $uids);

    # make sure the h11 doesn't leak
    $uids = $talk->search('fuzzy', 'body', 'xyzzy1') || die;
    $self->assert_deep_equals([], $uids);
    $uids = $talk->search('fuzzy', 'body', 'xyzzy') || die;
    $self->assert_deep_equals([1], $uids);
}

sub test_striphtml_plain
    :min_version_3_3 :needs_search_xapian
{
    my ($self) = @_;
    my $talk = $self->{store}->get_client();

    xlog "Index message with only plain text part";
    $self->make_message("test",
        body => ""
          . "<div>This is a plain text body with <b>html</b>.</div>\r\n"
    ) || die;
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    xlog "Assert that HTML in plain-text only isn't stripped";
    my $uids = $talk->search('fuzzy', 'body', 'html') || die;
    $self->assert_deep_equals([1], $uids);

    $uids = $talk->search('fuzzy', 'body', 'div') || die;
    $self->assert_deep_equals([1], $uids);
}

sub test_striphtml_rfc822
    :min_version_3_3 :needs_search_xapian
{
    my ($self) = @_;
    my $talk = $self->{store}->get_client();

    xlog "Index message with attached rfc822 message";
    $self->make_message("test",
        mime_type => "multipart/mixed",
        mime_boundary => "boundary_1",
        body => ""
          . "\r\n--boundary_1\r\n"
          . "Content-Type: text/plain; charset=\"UTF-8\"\r\n"
          . "\r\n"
          . "<main>plain</main>\r\n"
          . "\r\n--boundary_1\r\n"
          . "Content-Type: message/rfc822\r\n"
          . "\r\n"
          . "Subject: bar\r\n"
          . "From: from\@local\r\n"
          . "Date: Wed, 05 Oct 2016 14:59:07 +1100\r\n"
          . "To: to\@local\r\n"
          . "Mime-Version: 1.0\r\n"
          . "Content-Type: multipart/alternative; boundary=boundary_2\r\n"
          . "\r\n"
          . "\r\n--boundary_2\r\n"
          . "Content-Type: text/plain; charset=\"UTF-8\"\r\n"
          . "\r\n"
          . "<div>embeddedplain with <b>html</b>.</div>\r\n"
          . "\r\n--boundary_2\r\n"
          . "Content-Type: text/html; charset=\"UTF-8\"\r\n"
          . "\r\n"
          . "<div>embeddedhtml.</div>\r\n"
          . "\r\n--boundary_2--\r\n"
    ) || die;
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    xlog "Assert that HTML in top-level message isn't stripped";
    my $uids = $talk->search('fuzzy', 'body', 'main') || die;
    $self->assert_deep_equals([1], $uids);

    xlog "Assert that HTML in embedded message plain text is stripped";
    $uids = $talk->search('fuzzy', 'body', 'div') || die;
    $self->assert_deep_equals([], $uids);
    $uids = $talk->search('fuzzy', 'body', 'html') || die;
    $self->assert_deep_equals([1], $uids);
}

sub test_squatter_partials
    :min_version_3_3 :needs_search_xapian :SearchAttachmentExtractor :NoCheckSyslog
{
    my ($self) = @_;
    my $instance = $self->{instance};
    my $imap = $self->{store}->get_client();

    my $uri = URI->new($instance->{config}->get('search_attachment_extractor_url'));

    xlog "Start extractor server";
    my $nrequests = 0;
    my $handler = sub {
        my ($conn, $req) = @_;
        if ($req->method eq 'HEAD') {
            my $res = HTTP::Response->new(204);
            $res->content("");
            $conn->send_response($res);
        } else {
            $nrequests++;
            if ($nrequests <= 4) {
                # attach1: squatter sends GET and retries PUT 3 times
                $conn->send_error(500);
            } elsif ($nrequests == 5) {
                # attach2: squatter sends GET
                my $res = HTTP::Response->new(200);
                $res->content("attach2");
                $conn->send_response($res);
            } elsif ($nrequests == 6) {
                # attach1 retry: squatter sends GET
                my $res = HTTP::Response->new(200);
                $res->content("attach1");
                $conn->send_response($res);
            } else {
                xlog "Unexpected request";
                $conn->send_error(500);
            }
        }
    };
    $instance->start_httpd($handler, $uri->port());

    xlog "Append emails with PDF attachments to trigger extractor";
    $self->make_message("msg1",
        mime_type => "multipart/related",
        mime_boundary => "123456789abcdef",
        body => ""
        ."\r\n--123456789abcdef\r\n"
        ."Content-Type: text/plain\r\n"
        ."\r\n"
        ."bodyterm"
        ."\r\n--123456789abcdef\r\n"
        ."Content-Type: application/pdf\r\n"
        ."\r\n"
        ."attach1"
        ."\r\n--123456789abcdef--\r\n"
    ) || die;
    $self->make_message("msg2",
        mime_type => "multipart/related",
        mime_boundary => "123456789abcdef",
        body => ""
        ."\r\n--123456789abcdef\r\n"
        ."Content-Type: text/plain\r\n"
        ."\r\n"
        ."bodyterm"
        ."\r\n--123456789abcdef\r\n"
        ."Content-Type: application/pdf\r\n"
        ."\r\n"
        ."attach2"
        ."\r\n--123456789abcdef--\r\n"
    ) || die;

    xlog "Run squatter and allow partials";
    $self->{instance}->run_command({cyrus => 1}, 'squatter', '-p', '-Z');

    xlog "Assert text bodies of both messages are indexed";
    my $uids = $imap->search('fuzzy', 'body', 'bodyterm');
    $self->assert_deep_equals([1,2], $uids);

    xlog "Assert attachment of first message is not indexed";
    $uids = $imap->search('fuzzy', 'xattachmentbody', 'attach1');
    $self->assert_deep_equals([], $uids);

    xlog "Assert attachment of second message is indexed";
    $uids = $imap->search('fuzzy', 'xattachmentbody', 'attach2');
    $self->assert_deep_equals([2], $uids);

    xlog "Run incremental squatter without recovering partials";
    $self->{instance}->run_command({cyrus => 1}, 'squatter', '-i');

    xlog "Assert attachment of first message is not indexed";
    $uids = $imap->search('fuzzy', 'xattachmentbody', 'attach1');
    $self->assert_deep_equals([], $uids);

    xlog "Run incremental squatter with recovering partials";
    $self->{instance}->run_command({cyrus => 1}, 'squatter', '-i', '-P');

    xlog "Assert attachment of first message is indexed";
    $uids = $imap->search('fuzzy', 'xattachmentbody', 'attach1');
    $self->assert_deep_equals([1], $uids);
}

sub test_squatter_skip422
    :min_version_3_3 :needs_search_xapian :SearchAttachmentExtractor :NoCheckSyslog
{
    my ($self) = @_;
    my $instance = $self->{instance};
    my $imap = $self->{store}->get_client();

    my $uri = URI->new($instance->{config}->get('search_attachment_extractor_url'));

    xlog "Start extractor server";
    my $nrequests = 0;
    my $handler = sub {
        my ($conn, $req) = @_;
        if ($req->method eq 'HEAD') {
            my $res = HTTP::Response->new(204);
            $res->content("");
            $conn->send_response($res);
        } else {
            $conn->send_error(422);
        }
    };
    $instance->start_httpd($handler, $uri->port());

    xlog "Append emails with PDF attachments to trigger extractor";
    $self->make_message("msg1",
        mime_type => "multipart/related",
        mime_boundary => "123456789abcdef",
        body => ""
        ."\r\n--123456789abcdef\r\n"
        ."Content-Type: text/plain\r\n"
        ."\r\n"
        ."bodyterm"
        ."\r\n--123456789abcdef\r\n"
        ."Content-Type: application/pdf\r\n"
        ."\r\n"
        ."attach1"
        ."\r\n--123456789abcdef--\r\n"
    ) || die;
    $self->make_message("msg2",
        mime_type => "multipart/related",
        mime_boundary => "123456789abcdef",
        body => ""
        ."\r\n--123456789abcdef\r\n"
        ."Content-Type: text/plain\r\n"
        ."\r\n"
        ."bodyterm"
        ."\r\n--123456789abcdef\r\n"
        ."Content-Type: application/pdf\r\n"
        ."\r\n"
        ."attach2"
        ."\r\n--123456789abcdef--\r\n"
    ) || die;

    xlog "Run squatter and allow partials";
    $self->{instance}->run_command({cyrus => 1}, 'squatter', '-p', '-Z');

    xlog "Assert text bodies of both messages are indexed";
    my $uids = $imap->search('fuzzy', 'body', 'bodyterm');
    $self->assert_deep_equals([1,2], $uids);

    xlog "Assert attachment of first message is not indexed";
    $uids = $imap->search('fuzzy', 'xattachmentbody', 'attach1');
    $self->assert_deep_equals([], $uids);

    xlog "Assert attachment of second message is not indexed";
    $uids = $imap->search('fuzzy', 'xattachmentbody', 'attach2');
    $self->assert_deep_equals([], $uids);
}

sub test_fuzzyalways_annot
    :min_version_3_3 :needs_search_xapian :SearchFuzzyAlways
{
    my ($self) = @_;
    my $imap = $self->{store}->get_client();

    $self->make_message('test', body => 'body') || die;
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    xlog "Assert IMAP SEARCH uses fuzzy search by default";

    # Fuzzy search uses stemming.
    my $uids = $imap->search('body', 'bodies') || die;
    $self->assert_deep_equals([1], $uids);
    # But does not do substring search.
    $uids = $imap->search('body', 'bod') || die;
    $self->assert_deep_equals([], $uids);

    xlog "Disable fuzzy search with annotation";
    my $entry = '/shared/vendor/cmu/cyrus-imapd/search-fuzzy-always';

    # Must not set any mailbox other than INBOX.
    $imap->create("INBOX.foo") or die "create INBOX.foo: $@";
    $imap->setmetadata('INBOX.foo', $entry, 'off');
    $self->assert_str_equals('no', $imap->get_last_completion_response());
    # Must set a valid imapd.conf switch value.
    $imap->setmetadata('INBOX', $entry, 'x');
    $self->assert_str_equals('no', $imap->get_last_completion_response());
    # Set annotation value.
    $imap->setmetadata('INBOX', $entry, 'off');
    $self->assert_str_equals('ok', $imap->get_last_completion_response());

    xlog "Assert annotation overrides IMAP SEARCH default";

    # Regular search does no stemming.
    $uids = $imap->search('body', 'bodies') || die;
    $self->assert_deep_equals([], $uids);
    # But does substring search.
    $uids = $imap->search('body', 'bod') || die;
    $self->assert_deep_equals([1], $uids);

    xlog "Remove annotation and fall back to config";
    $imap->setmetadata('INBOX', $entry, undef);
    $self->assert_str_equals('ok', $imap->get_last_completion_response());

    # Fuzzy search uses stemming.
    $uids = $imap->search('body', 'bodies') || die;
    $self->assert_deep_equals([1], $uids);
    # But does not do substring search.
    $uids = $imap->search('body', 'bod') || die;
    $self->assert_deep_equals([], $uids);
}

sub run_delve {
    my ($self, $dir, @args) = @_;
    my $basedir = $self->{instance}->{basedir};
    my @myargs = ('delve');
    push(@myargs, @args);
    push(@myargs, $dir);
    $self->{instance}->run_command({redirects => {stdout => "$basedir/delve.out"}}, @myargs);
    open(FH, "<$basedir/delve.out") || die "can't find delve.out";
    my $data = <FH>;
    return $data;
}

sub delve_docs
{
    my ($self, $dir) = @_;
    my $delveout = $self->run_delve($dir, '-V0');
    $delveout =~ s/^Value 0 for each document: //;
    my @docs = split ' ', $delveout;
    my @parts = map { $_ =~ /^\d+:\*P\*/ ? substr($_, 5) : () } @docs;
    my @gdocs = map { $_ =~ /^\d+:\*G\*/ ? substr($_, 5) : () } @docs;
    return \@gdocs, \@parts;
}

sub test_dedup_part_index
    :min_version_3_3 :needs_search_xapian
{
    my ($self) = @_;

    my $xapdirs = ($self->{instance}->run_mbpath(-u => 'cassandane'))->{xapian};

    $self->make_message('msgA', body => 'part1') || die;
    $self->make_message('msgB', body => 'part2') || die;

    xlog "create duplicate part within the same indexing batch";
    $self->make_message('msgC', body => 'part1') || die;
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    xlog "create duplicate part in another indexing batch";
    $self->make_message('msgD', body => 'part1') || die;
    $self->{instance}->run_command({cyrus => 1}, 'squatter', '-i');

    xlog "assert deduplicated parts";
    my $delveout = $self->run_delve($xapdirs->{t1} . '/xapian', '-V0');
    $delveout =~ s/^Value 0 for each document: //;
    my @docs = split ' ', $delveout;
    my @parts = map { $_ =~ /^\d+:\*P\*/ ? substr($_, 5) : () } @docs;
    my @gdocs = map { $_ =~ /^\d+:\*G\*/ ? substr($_, 5) : () } @docs;
    $self->assert_num_equals(2, scalar @parts);
    $self->assert_str_not_equals($parts[0], $parts[1]);
    $self->assert_num_equals(4, scalar @gdocs);

    xlog "compact to t2 tier";
    $self->{instance}->run_command({cyrus => 1}, 'squatter', '-z', 't2', '-t', 't1');

    xlog "create duplicate part in top tier";
    $self->make_message('msgD', body => 'part1') || die;
    $self->{instance}->run_command({cyrus => 1}, 'squatter', '-i');

    xlog "Assert deduplicated parts across tiers";
    $delveout = $self->run_delve($xapdirs->{t1}. '/xapian.1', '-V0');
    $delveout =~ s/^Value 0 for each document: //;
    @docs = split ' ', $delveout;
    @parts = map { $_ =~ /^\d+:\*P\*/ ? substr($_, 5) : () } @docs;
    @gdocs = map { $_ =~ /^\d+:\*G\*/ ? substr($_, 5) : () } @docs;
    $self->assert_num_equals(0, scalar @parts);
    $self->assert_num_equals(1, scalar @gdocs);
}

sub test_dedup_part_compact
    :min_version_3_3 :needs_search_xapian
{
    my ($self) = @_;

    my $xapdirs = ($self->{instance}->run_mbpath(-u => 'cassandane'))->{xapian};

    xlog "force duplicate part into index";
    $self->make_message('msgA', body => 'part1') || die;
    $self->make_message('msgB', body => 'part1') || die;
    $self->{instance}->run_command({cyrus => 1}, 'squatter', '-D');

    xlog "assert duplicated parts";
    my ($gdocs, $parts) = $self->delve_docs($xapdirs->{t1} . "/xapian");
    $self->assert_num_equals(2, scalar @$parts);
    $self->assert_str_equals(@$parts[0], @$parts[1]);
    $self->assert_num_equals(2, scalar @$gdocs);

    xlog "compact and filter to t2 tier";
    $self->{instance}->run_command({cyrus => 1}, 'squatter', '-z', 't2', '-t', 't1', '-F');

    xlog "assert parts got deduplicated";
    ($gdocs, $parts) = $self->delve_docs($xapdirs->{t2} . "/xapian");
    $self->assert_num_equals(1, scalar @$parts);
    $self->assert_num_equals(2, scalar @$gdocs);

    xlog "force duplicate part into t1 index";
    $self->make_message('msgC', body => 'part1') || die;
    $self->{instance}->run_command({cyrus => 1}, 'squatter', '-i', '-D');

    xlog "compact and filter to t3 tier";
    $self->{instance}->run_command({cyrus => 1}, 'squatter', '-z', 't3', '-t', 't1,t2', '-F');

    xlog "assert parts got deduplicated";
    ($gdocs, $parts) = $self->delve_docs($xapdirs->{t3} . "/xapian");
    $self->assert_num_equals(1, scalar @$parts);
    $self->assert_num_equals(3, scalar @$gdocs);
}

sub test_reindex_mb_uniqueid
    :min_version_3_7 :needs_search_xapian
{
    my ($self) = @_;

    my $xapdirs = ($self->{instance}->run_mbpath(-u => 'cassandane'))->{xapian};
    my $basedir = $self->{instance}->{basedir};

    $self->make_message('msgA', body => 'part1') || die;
    $self->make_message('msgB', body => 'part1') || die;
    $self->{instance}->run_command({cyrus => 1}, 'squatter', '-D');

    xlog "compact and reindex tier";
    $self->{instance}->run_command({cyrus => 1}, 'squatter', '-v', '-z', 't2', '-t', 't1', '-T', 't1:0');

    xlog "dump t2:cyrus.indexed.db";
    # assumes twoskip backend and version 2 format keys
    my $srcfile = $xapdirs->{t2} . '/xapian/cyrus.indexed.db';
    my $dstfile = $basedir . '/tmp/cyrus.indexed.db.flat';
    $self->{instance}->run_command({cyrus => 1}, 'cvt_cyrusdb', $srcfile, 'twoskip', $dstfile, 'flat');

    xlog "assert reindexed tier contains a mailbox key";
    open(FH, "<$dstfile") || die;
    my @mboxrows = grep { /^\*M\*[0-9a-zA-z\-_]+\*/ } <FH>;
    close FH;
    $self->assert_num_equals(1, scalar @mboxrows);
}

sub start_echo_extractor
{
    my ($self, %params) = @_;
    my $instance = $self->{instance};

    xlog "Start extractor server with tracedir $params{tracedir}";
    my $nrequests = 0;
    my $handler = sub {
        my ($conn, $req) = @_;

        $nrequests++;

        if ($params{trace_delay_seconds}) {
            sleep $params{trace_delay_seconds};
        }

        if ($params{tracedir}) {
            # touch trace file in tracedir
            my @paths = split(q{/}, URI->new($req->uri)->path);
            my $guid = pop(@paths);
            my $fname = join(q{},
                $params{tracedir}, "/req", $nrequests, "_", $req->method, "_$guid");
            open(my $fh, ">", $fname) or die "Can't open > $fname: $!";
            close $fh;
        }

        my $res;

        if ($req->method eq 'HEAD') {
            $res = HTTP::Response->new(204);
            $res->content("");
        } elsif ($req->method eq 'GET') {
            $res = HTTP::Response->new(404);
            $res->content("nope");
        } else {
            $res = HTTP::Response->new(200);
            $res->content($req->content);
        }

        if ($params{response_delay_seconds}) {
            my $secs = $params{response_delay_seconds};
            if (ref($secs) eq 'ARRAY') {
                $secs = ($nrequests <= scalar @$secs) ?
                    $secs->[$nrequests-1] : 0;
            }
            sleep $secs;
        }

        $conn->send_response($res);
    };

    my $uri = URI->new($instance->{config}->get('search_attachment_extractor_url'));
    $instance->start_httpd($handler, $uri->port());
}

sub squatter_attachextract_cache_run
{
    my ($self, $cachedir, @squatterArgs) = @_;
    my $instance = $self->{instance};
    my $imap = $self->{store}->get_client();

    xlog "Append emails with identical attachments";
    $self->make_message("msg1",
        mime_type => "multipart/related",
        mime_boundary => "123456789abcdef",
        body => ""
        ."\r\n--123456789abcdef\r\n"
        ."Content-Type: text/plain\r\n"
        ."\r\n"
        ."bodyterm"
        ."\r\n--123456789abcdef\r\n"
        ."Content-Type: application/pdf\r\n"
        ."\r\n"
        ."attachterm"
        ."\r\n--123456789abcdef--\r\n"
    ) || die;
    $self->make_message("msg2",
        mime_type => "multipart/related",
        mime_boundary => "123456789abcdef",
        body => ""
        ."\r\n--123456789abcdef\r\n"
        ."Content-Type: text/plain\r\n"
        ."\r\n"
        ."bodyterm"
        ."\r\n--123456789abcdef\r\n"
        ."Content-Type: application/pdf\r\n"
        ."\r\n"
        ."attachterm"
        ."\r\n--123456789abcdef--\r\n"
    ) || die;

    xlog "Run squatter with cachedir $cachedir";
    $self->{instance}->run_command({cyrus => 1},
        'squatter', "--attachextract-cache-dir=$cachedir", @squatterArgs);
}

sub test_squatter_attachextract_cache
    :min_version_3_9 :needs_search_xapian :SearchAttachmentExtractor
{
    my ($self) = @_;
    my $instance = $self->{instance};
    my $imap = $self->{store}->get_client();

    my $tracedir = tempdir(DIR => $instance->{basedir} . "/tmp");
    $self->start_echo_extractor(tracedir => $tracedir);

    xlog "Create and index index messages";
    my $cachedir = tempdir(DIR => $instance->{basedir} . "/tmp");
    $self->squatter_attachextract_cache_run($cachedir);

    xlog "Assert text bodies of both messages are indexed";
    my $uids = $imap->search('fuzzy', 'body', 'bodyterm');
    $self->assert_deep_equals([1,2], $uids);

    xlog "Assert attachments of both messages are indexed";
    $uids = $imap->search('fuzzy', 'xattachmentbody', 'attachterm');
    $self->assert_deep_equals([1,2], $uids);

    xlog "Assert extractor only got called once";
    my @tracefiles = glob($tracedir."/*_PUT_*");
    $self->assert_num_equals(1, scalar @tracefiles);

    xlog "Assert cache contains one file";
    my @files = glob($cachedir."/*");
    $self->assert_num_equals(1, scalar @files);
}

sub test_squatter_attachextract_cachedir_noperm
    :min_version_3_9 :needs_search_xapian :SearchAttachmentExtractor :NoCheckSyslog
{
    my ($self) = @_;
    my $instance = $self->{instance};
    my $imap = $self->{store}->get_client();

    my $tracedir = tempdir(DIR => $instance->{basedir} . "/tmp");
    $self->start_echo_extractor(tracedir => $tracedir);

    xlog "Run squatter with read-only cache directory";
    my $cachedir = tempdir(DIR => $instance->{basedir} . "/tmp");
    chmod 0400, $cachedir || die;
    $self->squatter_attachextract_cache_run($cachedir, "--allow-partials");

    xlog "Assert text bodies of both messages are indexed";
    my $uids = $imap->search('fuzzy', 'body', 'bodyterm');
    $self->assert_deep_equals([1,2], $uids);

    xlog "Assert attachments of both messages are not indexed";
    $uids = $imap->search('fuzzy', 'xattachmentbody', 'attachterm');
    $self->assert_deep_equals([], $uids);

    xlog "Assert extractor got called twice with attachment uploads";
    my @tracefiles = glob($tracedir."/*_PUT_*");
    $self->assert_num_equals(2, scalar @tracefiles);

    xlog "Assert cache contains no file";
    chmod 0700, $cachedir || die;
    my @files = glob($cachedir."/*");
    $self->assert_num_equals(0, scalar @files);
}

sub test_squatter_attachextract_cacheonly
    :min_version_3_9 :needs_search_xapian :SearchAttachmentExtractor :NoCheckSyslog
{
    my ($self) = @_;
    my $instance = $self->{instance};
    my $imap = $self->{store}->get_client();

    my $tracedir = tempdir(DIR => $instance->{basedir} . "/tmp");
    $self->start_echo_extractor(tracedir => $tracedir);

    xlog "Instruct squatter to only use attachextract cache";
    my $cachedir = tempdir(DIR => $instance->{basedir} . "/tmp");
    $self->squatter_attachextract_cache_run($cachedir,
        "--attachextract-cache-only", "--allow-partials");

    xlog "Assert text bodies of both messages are indexed";
    my $uids = $imap->search('fuzzy', 'body', 'bodyterm');
    $self->assert_deep_equals([1,2], $uids);

    xlog "Assert attachments of both messages are not indexed";
    $uids = $imap->search('fuzzy', 'xattachmentbody', 'attachterm');
    $self->assert_deep_equals([], $uids);

    xlog "Assert extractor did not get got called";
    my @tracefiles = glob($tracedir."/*");
    $self->assert_num_equals(0, scalar @tracefiles);

    xlog "Assert cache contains no file";
    my @files = glob($cachedir."/*");
    $self->assert_num_equals(0, scalar @files);
}

sub test_squatter_attachextract_nolock
    :min_version_3_9 :needs_search_xapian :SearchAttachmentExtractor
{
    my ($self) = @_;
    my $instance = $self->{instance};
    my $imap = $self->{store}->get_client();

    my $tracedir = tempdir(DIR => $instance->{basedir} . "/tmp");
    $self->start_echo_extractor(
        tracedir => $tracedir,
        trace_delay_seconds => 1,
        response_delay_seconds => 1,
    );

    xlog $self, "Make plain text message";
    $self->make_message("msg1",
        mime_type => "text/plain",
        body => "bodyterm");

    xlog $self, "Make message with attachment";
    $self->make_message("msg2",
        mime_type => "multipart/related",
        mime_boundary => "123456789abcdef",
        body => ""
        ."\r\n--123456789abcdef\r\n"
        ."Content-Type: text/plain\r\n"
        ."\r\n"
        ."bodyterm"
        ."\r\n--123456789abcdef\r\n"
        ."Content-Type: application/pdf\r\n"
        ."Content-Transfer-Encoding: base64\r\n"
        ."\r\n"
        # that's "attachterm"
        ."YXR0YWNodGVybQo="
        ."\r\n--123456789abcdef--\r\n");

    xlog $self, "Clear syslog";
    $self->{instance}->getsyslog();

    xlog $self, "Run squatter";
    $self->{instance}->run_command({cyrus => 1}, 'squatter', '-v');

    xlog $self, "Inspect syslog and extractor trace files";
    my @log = $self->{instance}->getsyslog(qr/squatter\[\d+\]: (released|reacquired) mailbox lock/);

    my ($released_timestamp) = ($log[0] =~ /released.+unixepoch=<(\d+)>/);
    $self->assert_not_null($released_timestamp);

    my @tracefiles = glob($tracedir."/*_PUT_*");
    $self->assert_num_equals(1, scalar @tracefiles);
    my $extractor_timestamp = stat($tracefiles[0])->ctime;
    $self->assert_not_null($extractor_timestamp);

    my ($reacquired_timestamp) = ($log[1] =~ /reacquired.+unixepoch=<(\d+)>/);
    $self->assert_not_null($reacquired_timestamp);

    xlog $self, "Assert extractor got called without mailbox lock";
    $self->assert_num_lt($extractor_timestamp, $released_timestamp);
    $self->assert_num_lt($reacquired_timestamp, $extractor_timestamp);

    xlog $self, "Assert terms actually got indexed";
    my $uids = $imap->search('fuzzy', 'body', 'bodyterm');
    $self->assert_deep_equals([1,2], $uids);

    $uids = $imap->search('fuzzy', 'xattachmentbody', 'attachterm');
    $self->assert_deep_equals([2], $uids);
}

sub test_squatter_attachextract_timeout
    :min_version_3_9 :needs_search_xapian :SearchAttachmentExtractor :NoCheckSyslog
{
    my ($self) = @_;
    my $instance = $self->{instance};
    my $imap = $self->{store}->get_client();

    my $tracedir = tempdir (DIR => $instance->{basedir} . "/tmp");

    # SearchAttachmentExtractor magic configures Cyrus to
    # wait at most 3 seconds for a response from extractor

    $self->start_echo_extractor(
        tracedir => $tracedir,
        response_delay_seconds => [5], # timeout on first request only
    );

    xlog $self, "Make message with attachment";
    $self->make_message("msg1",
        mime_type => "multipart/related",
        mime_boundary => "123456789abcdef",
        body => ""
        ."\r\n--123456789abcdef\r\n"
        ."Content-Type: text/plain\r\n"
        ."\r\n"
        ."bodyterm"
        ."\r\n--123456789abcdef\r\n"
        ."Content-Type: application/pdf\r\n"
        ."\r\n"
        ."attachterm"
        ."\r\n--123456789abcdef--\r\n");

    xlog $self, "Run squatter (allowing partials)";
    $self->{instance}->run_command({cyrus => 1}, 'squatter', '-v', '-p');

    xlog "Assert text body is indexed";
    my $uids = $imap->search('fuzzy', 'body', 'bodyterm');
    $self->assert_deep_equals([1], $uids);

    xlog "Assert attachement is not indexed";
    $uids = $imap->search('fuzzy', 'xattachmentbody', 'attachterm');
    $self->assert_deep_equals([], $uids);

    xlog "Assert extractor got called once";
    my @tracefiles = glob($tracedir."/*");
    $self->assert_num_equals(1, scalar @tracefiles);
    $self->assert_matches(qr/req1_GET_/, $tracefiles[0]);

    xlog $self, "Rerun squatter for partials";
    $self->{instance}->run_command({cyrus => 1}, 'squatter', '-v', '-i', '-P');

    xlog "Assert text body is indexed";
    $uids = $imap->search('fuzzy', 'body', 'bodyterm');
    $self->assert_deep_equals([1], $uids);

    xlog "Assert attachement is indexed";
    $uids = $imap->search('fuzzy', 'xattachmentbody', 'attachterm');
    $self->assert_deep_equals([1], $uids);

    xlog "Assert extractor got called three times";
    @tracefiles = glob($tracedir."/*");
    $self->assert_num_equals(3, scalar @tracefiles);
    $self->assert_matches(qr/req1_GET_/, $tracefiles[0]);
    $self->assert_matches(qr/req2_GET_/, $tracefiles[1]);
    $self->assert_matches(qr/req3_PUT_/, $tracefiles[2]);
}

sub test_squatter_attachextract_unprocessable_content
    :min_version_3_9 :needs_search_xapian :SearchAttachmentExtractor :NoCheckSyslog
{
    my ($self) = @_;
    my $instance = $self->{instance};
    my $imap = $self->{store}->get_client();

    my $tracedir = tempdir (DIR => $instance->{basedir} . "/tmp");
    my $nrequests = 0;

    xlog "Start extractor server";
    my $handler = sub {
        my ($conn, $req) = @_;

        $nrequests++;

        # touch trace file in tracedir
        my @paths = split(q{/}, URI->new($req->uri)->path);
        my $guid = pop(@paths);
        my $fname = join(q{},
            $tracedir, "/req", $nrequests, "_", $req->method, "_$guid");
        open(my $fh, ">", $fname) or die "Can't open > $fname: $!";
        close $fh;

        my $res;

        if ($req->method eq 'HEAD') {
            $res = HTTP::Response->new(404);
            $res->content("");
        } elsif ($req->method eq 'GET') {
            $res = HTTP::Response->new(404);
            $res->content("nope");
        } else {
            # return HTTP 422 Unprocessable Content
            $res = HTTP::Response->new(422);
            $res->content("nope");
        }

        $conn->send_response($res);
    };

    my $uri = URI->new($instance->{config}->get('search_attachment_extractor_url'));
    $instance->start_httpd($handler, $uri->port());

    xlog $self, "Make message with unprocessable attachment";
    $self->make_message("msg1",
        mime_type => "multipart/related",
        mime_boundary => "123456789abcdef",
        body => ""
        ."\r\n--123456789abcdef\r\n"
        ."Content-Type: text/plain\r\n"
        ."\r\n"
        ."bodyterm"
        ."\r\n--123456789abcdef\r\n"
        ."Content-Type: application/octet-stream\r\n"
        ."\r\n"
        ."attachterm"
        ."\r\n--123456789abcdef--\r\n");

    xlog $self, "Run squatter (allowing partials)";
    $self->{instance}->run_command({cyrus => 1}, 'squatter', '-v', '-p');

    xlog "Assert text body is indexed";
    my $uids = $imap->search('fuzzy', 'body', 'bodyterm');
    $self->assert_deep_equals([1], $uids);

    xlog "Assert attachement is not indexed";
    $uids = $imap->search('fuzzy', 'xattachmentbody', 'attachterm');
    $self->assert_deep_equals([], $uids);

    xlog "Assert extractor got called";
    my @tracefiles = glob($tracedir."/*");
    $self->assert_num_equals(2, scalar @tracefiles);
    $self->assert_matches(qr/req1_GET_/, $tracefiles[0]);
    $self->assert_matches(qr/req2_PUT_/, $tracefiles[1]);

    xlog $self, "Rerun squatter for partials";
    $self->{instance}->run_command({cyrus => 1}, 'squatter', '-v', '-i', '-P');

    xlog "Assert text body is indexed";
    $uids = $imap->search('fuzzy', 'body', 'bodyterm');
    $self->assert_deep_equals([1], $uids);

    xlog "Assert attachement is not indexed";
    $uids = $imap->search('fuzzy', 'xattachmentbody', 'attachterm');
    $self->assert_deep_equals([], $uids);

    xlog "Assert extractor got called no more time";
    @tracefiles = glob($tracedir."/*");
    $self->assert_num_equals(2, scalar @tracefiles);
    $self->assert_matches(qr/req1_GET_/, $tracefiles[0]);
    $self->assert_matches(qr/req2_PUT_/, $tracefiles[1]);
}

1;

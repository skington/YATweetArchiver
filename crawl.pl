#!/usr/bin/env perl

use 5.14.0;
use warnings;
no warnings qw(uninitialized);

use lib::abs;
use Carp;
use Encode;
use English;
use Net::Twitter;
use LWP;

# Get our configuration file, connect to Twitter.
my $conf = do(lib::abs::path('oauth'))
    or die "Couldn't find oauth config file: $OS_ERROR";
my $twitter = Net::Twitter->new(
    traits => ['API::REST', 'OAuth', 'InflateObjects', 'RetryOnError'],
    %$conf
);

# FIXME: define this configuration path better.
my $dir_tweets = lib::abs::path('tweets');

# Get a user agent.
my $useragent = LWP::UserAgent->new(agent => 'YATweetArchiver/0.1');

# Find the most recent tweets.
my $page = 1;
page:
while (1) {
    print "Page $page...\n\n";
    my $tweets = $twitter->home_timeline({ page => $page++ });
    last page if ref($tweets) ne 'ARRAY';

    for my $tweet (@$tweets) {
        store_tweet($tweet);
    }
    
    print "Sleeping for a bit...\n";
    sleep 2;
}

print "That's all twitter will give us\n";

sub store_tweet {
    my ($tweet) = @_;
    
    # Find the content of the tweet - fetch the original if it was truncated
    # by a retweet.
    my $text = $tweet->text;
    if ($tweet->truncated && $tweet->retweeted_status) {
        $text = $tweet->retweeted_status->text;
    }
    
    # Find out when this tweet was created, and fetch the date parts
    # we'll use for our subdirectories.
    my $date = $tweet->created_at;
    my @date_parts = ($date->year, $date->month, $date->day);
    
    # Store the tweet.
    my $subdir = ensuresubdir($dir_tweets, @date_parts);
    store($subdir, $tweet->id,
        sprintf(
            "%s wrote on %s:\n%s",
            $tweet->user->screen_name,
            $date->ymd . ' ' . $date->hms(':'),
            $text
        )
    );
    print $tweet->user->screen_name, ': ', Encode::encode('UTF-8', $text),
        "\n";
        
    # Add a reference to the user.
    my $user_subdir
        = ensuresubdir($dir_tweets, 'users', $tweet->user->screen_name,
        @date_parts);
    my $tweet_path      = $subdir . '/' . $tweet->id;
    my $tweet_path_user = $user_subdir . '/' . $tweet->id;
    if (!-e $tweet_path_user) {
        link($tweet_path, $tweet_path_user)
            or carp "Couldn't link $tweet_path to $user_subdir: $OS_ERROR";
    }
    
    # Extract any links.
    url:
    for my $url ($text =~ m{ ( http s? ://t.co/ [a-zA-Z0-9]+ ) }gx) {
        my $url_subdir
            = ensuresubdir($dir_tweets, 'urls', @date_parts, $tweet->id);
        next url if -e $url_subdir . '/contents';

        print "Fetching $url\n";
        my $response = $useragent->get($url);
        if (!$response->is_success) {
            carp "Couldn't fetch $url:", $response->status;
            next url;
        }
        store($url_subdir, 'origurl', $url);
        store($url_subdir, 'url', $response->request->uri->as_string);
        store($url_subdir, 'contents', $response->decoded_content);
    }
    print "\n";
}

# Passed a directory path and an optional list of leafnames, ensures that
# a directory matching all of them exists.

sub ensuresubdir {
    my $dirpath;
    
    while (@_) {
        my $leafname = shift;
        $dirpath = $dirpath ? join('/', $dirpath, $leafname) : $leafname;
        if (!-e $dirpath) {
            mkdir($dirpath, 0700);
        }
    }
    return $dirpath;
}

# Passed a subdirectory, a leafname, and a scalar, writes said scalar to
# the file identified by the subdirectory and the leafname.

sub store {
    my ($subdir, $leafname, $contents)= @_;

    ensuresubdir($subdir);
    return 1 if -e (my $filename = $subdir . '/' . $leafname);
    open(my $fh, '>', $filename) or do {
        carp "Couldn't write $leafname to $subdir: $OS_ERROR";
        return;
    };
    print $fh Encode::encode('UTF-8', $contents);
    close $fh;
}

1;
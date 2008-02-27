#!/usr/bin/perl -w
# mysqltuner.pl - Version 0.8.6
# High Performance MySQL Tuning Script
# Copyright (C) 2006-2008 Major Hayden - major@mhtx.net
#
# For the latest updates, please visit http://mysqltuner.com/
# Subversion repository available at http://tools.assembla.com/svn/mysqltuner/
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# This project would not be possible without help from:
#   Matthew Montgomery
#   Paul Kehrer
#   Dave Burgess
#   Jonathan Hinds
#   Mike Jackson
#   Nils Breunese
#   Shawn Ashlee
#
# Inspired by Matthew Montgomery's tuning-primer.sh script:
# http://forge.mysql.com/projects/view.php?id=44
#
use strict;
use warnings;
use diagnostics;
use Getopt::Long;

# Set up a few variables for use in the script
my $tunerversion = "0.8.6";
my (@adjvars, @generalrec);

# Set defaults
my %opt = (
		"nobad" => 0,
		"nogood" => 0,
		"noinfo" => 0,
		"nocolor" => 0,
	);
	
# Gather the options from the command line
GetOptions(\%opt,
		'nobad',
		'nogood',
		'noinfo',
		'nocolor',
		'help',
	);

if (defined $opt{'help'} && $opt{'help'} == 1) { usage(); }

sub usage {
	# Shown with --help option passed
	print "\n".
		"	MySQLTuner $tunerversion - MySQL High Performance Tuning Script\n".
		"	Bug reports, feature requests, and downloads at http://mysqltuner.com/\n".
		"	Maintained by Major Hayden (major\@mhtx.net)\n\n".
		"	Important Usage Guidelines:\n".
		"	   To run the script with the default options, run the script without arguments\n".
		"	   Allow MySQL server to run for at least 24-48 hours before trusting suggestions\n".
		"	   Some routines may require root level privileges (script will provide warnings)\n\n".
		"	Output Options:\n".
		"	   --nogood         Remove OK responses\n".
		"	   --nobad          Remove negative/suggestion responses\n".
		"	   --noinfo         Remove informational responses\n".
		"	   --nocolor        Don't print output in color\n".
		"\n";
	exit;
}

# Setting up the colors for the print styles
my $good = ($opt{nocolor} == 0)? "[\e[00;32mOK\e[00m]" : "[OK]" ;
my $bad = ($opt{nocolor} == 0)? "[\e[00;31m!!\e[00m]" : "[!!]" ;
my $info = ($opt{nocolor} == 0)? "[\e[00;34m--\e[00m]" : "[--]" ;

# Functions that handle the print styles
sub goodprint { print $good." ".$_[0] unless ($opt{nogood} == 1); }
sub infoprint { print $info." ".$_[0] unless ($opt{noinfo} == 1); }
sub badprint { print $bad." ".$_[0] unless ($opt{nobad} == 1); }
sub redwrap { return ($opt{nocolor} == 0)? "\e[00;31m".$_[0]."\e[00m" : $_[0] ; }
sub greenwrap { return ($opt{nocolor} == 0)? "\e[00;32m".$_[0]."\e[00m" : $_[0] ; }

# Calculates the parameter passed in bytes, and then rounds it to one decimal place
sub hr_bytes {
	my $num = shift;
	if ($num >= (1024**3)) { #GB
		return sprintf("%.1f",($num/(1024**3)))."G";
	} elsif ($num >= (1024**2)) { #MB
		return sprintf("%.1f",($num/(1024**2)))."M";
	} elsif ($num >= 1024) { #KB
		return sprintf("%.1f",($num/1024))."K";
	} else {
		return $num."B";
	}
}

# Calculates the parameter passed in bytes, and then rounds it to the nearest integer
sub hr_bytes_rnd {
	my $num = shift;
	if ($num >= (1024**3)) { #GB
		return int(($num/(1024**3)))."G";
	} elsif ($num >= (1024**2)) { #MB
		return int(($num/(1024**2)))."M";
	} elsif ($num >= 1024) { #KB
		return int(($num/1024))."K";
	} else {
		return $num."B";
	}
}

# Calculates the parameter passed to the nearest power of 1000, then rounds it to the nearest integer
sub hr_num {
	my $num = shift;
	if ($num >= (1000**3)) { # Billions
		return int(($num/(1000**3)))."B";
	} elsif ($num >= (1000**2)) { # Millions
		return int(($num/(1000**2)))."M";
	} elsif ($num >= 1000) { # Thousands
		return int(($num/1000))."K";
	} else {
		return $num;
	}
}

# Calculates uptime to display in a more attractive form
sub pretty_uptime {
	my $uptime = shift;
	my $seconds = $uptime % 60;
	my $minutes = int(($uptime % 3600) / 60);
	my $hours = int(($uptime % 86400) / (3600));
	my $days = int($uptime / (86400));
	my $uptimestring;
	if ($days > 0) {
		$uptimestring = "${days}d ${hours}h ${minutes}m ${seconds}s";
	} elsif ($hours > 0) {
		$uptimestring = "${hours}h ${minutes}m ${seconds}s";
	} elsif ($minutes > 0) {
		$uptimestring = "${minutes}m ${seconds}s";
	} else {
		$uptimestring = "${seconds}s";
	}
	return $uptimestring;
}

# Retrieves the memory installed on this machine
my ($physical_memory,$swap_memory,$duflags);
sub os_setup {
	my $os = `uname`;
	$duflags = '';
	if ($os =~ /Linux/) {
		$physical_memory = `free -b | grep Mem | awk '{print \$2}'`;
		$swap_memory = `free -b | grep Swap | awk '{print \$2}'`;
		$duflags = '-b';
	} elsif ($os =~ /Darwin/) {
		$physical_memory = `sysctl -n hw.memsize`;
		$swap_memory = `sysctl -n vm.swapusage | awk '{print \$3}' | sed 's/\..*\$//'`;
	} elsif ($os =~ /NetBSD/) {
		$physical_memory = `sysctl -n hw.physmem`;
		$swap_memory = `swapctl -l | grep '^/' | awk '{ s+= \$2 } END { print s }'`;
	} elsif ($os =~ /BSD/) {
		$physical_memory = `sysctl -n hw.realmem`;
		$swap_memory = `swapinfo | grep '^/' | awk '{ s+= \$2 } END { print s }'`;
	}
	chomp($physical_memory);
}

# Checks to see if a MySQL login is possible
my $mysqllogin;
sub mysql_setup {
	my $command = `which mysqladmin`;
	chomp($command);
	if (! -e $command) {
		badprint "Unable to find mysqladmin in your \$PATH.  Is MySQL installed?\n";
		exit;
	}
	if ( -r "/etc/psa/.psa.shadow" ) {
		# It's a Plesk box, use the available credentials
		$mysqllogin = "-u admin -p`cat /etc/psa/.psa.shadow`";
		my $loginstatus = `mysqladmin ping $mysqllogin 2>&1`;
		unless ($loginstatus =~ /mysqld is alive/) {
			badprint "Attempted to use login credentials from Plesk, but they failed.\n";
			exit 0;
		}
	} else {
		# It's not Plesk, we should try a login
		my $loginstatus = `mysqladmin ping 2>&1`;
		if ($loginstatus =~ /mysqld is alive/) {
			# Login went just fine
			$mysqllogin = "";
			# Did this go well because of a .my.cnf file or is there no password set?
			my $userpath = `ls -d ~`;
			chomp($userpath);
			unless ( -e "$userpath/.my.cnf" ) {
				badprint "Successfully authenticated with no password - SECURITY RISK!\n";
			}
			return 1;
		} else {
			print STDERR "Please enter your MySQL administrative login: ";
			my $name = <>;
			print STDERR "Please enter your MySQL administrative password: ";
			system("stty -echo");
			my $password = <>;
			system("stty echo");
			chomp($password);
			chomp($name);
			$mysqllogin = "-u $name -p'$password'";
			my $loginstatus = `mysqladmin ping $mysqllogin 2>&1`;
			if ($loginstatus =~ /mysqld is alive/) {
				print STDERR "\n";
				return 1;
			} else {
				print "\n".$bad." Attempted to use login credentials, but they were invalid.\n";
				exit 0;
			}
			exit 0;
		}
	}
}

# Populates all of the variable and status hashes
my (%mystat,%myvar,$dummyselect);
sub get_all_vars {
	# We need to initiate at least one query so that our data is useable
	$dummyselect = `mysql $mysqllogin -Bse "SELECT VERSION();"`;
	my @mysqlvarlist = `mysql $mysqllogin -Bse "SHOW /*!50000 GLOBAL */ VARIABLES;"`;
	foreach my $line (@mysqlvarlist) {
		$line =~ /([a-zA-Z_]*)\s*(.*)/;
		$myvar{$1} = $2;
	}
	my @mysqlstatlist = `mysql $mysqllogin -Bse "SHOW /*!50000 GLOBAL */ STATUS;"`;
	foreach my $line (@mysqlstatlist) {
		$line =~ /([a-zA-Z_]*)\s*(.*)/;
		$mystat{$1} = $2;
	}
}

# Checks for supported or EOL'ed MySQL versions
my ($mysqlvermajor,$mysqlverminor);
sub validate_mysql_version {
	print "\n-------- General Statistics --------------------------------------------------\n";
	($mysqlvermajor,$mysqlverminor) = $myvar{'version'} =~ /(\d)\.(\d)/;
	if ($mysqlvermajor < 5) {
		badprint "Your MySQL version ".$myvar{'version'}." is EOL software!  Upgrade soon!\n";
	} elsif ($mysqlvermajor == 5) {
		goodprint "Currently running supported MySQL version ".$myvar{'version'}."\n";
	} else {
		badprint "Currently running unsupported MySQL version ".$myvar{'version'}."\n";
	}
}

# Checks for 32-bit boxes with more than 2GB of RAM
my ($arch);
sub check_architecture {
	if (`uname -m` =~ /64/) {
		$arch = 64;
		goodprint "Operating on 64-bit architecture\n";
	} else {
		$arch = 32;
		if ($physical_memory > 2147483648) {
			badprint "Switch to 64-bit OS - MySQL cannot currenty use all of your RAM\n";
		} else {
			goodprint "Operating on 32-bit architecture with less than 2GB RAM\n";
		}
	}
}

# Start up a ton of storage engine counts/statistics
my (%enginestats,%enginecount);
sub check_storage_engines {
	print "\n-------- Storage Engine Statistics -------------------------------------------\n";
	infoprint "Status: ";
	my $engines;
	$engines .= (defined $myvar{'have_archive'} && $myvar{'have_archive'} eq "YES")? greenwrap "+Archive " : redwrap "-Archive " ;
	$engines .= (defined $myvar{'have_bdb'} && $myvar{'have_bdb'} eq "YES")? greenwrap "+BDB " : redwrap "-BDB " ;
	$engines .= (defined $myvar{'have_federated'} && $myvar{'have_federated'} eq "YES")? greenwrap "+Federated " : redwrap "-Federated " ;
	$engines .= (defined $myvar{'have_innodb'} && $myvar{'have_innodb'} eq "YES")? greenwrap "+InnoDB " : redwrap "-InnoDB " ;
	$engines .= (defined $myvar{'have_isam'} && $myvar{'have_isam'} eq "YES")? greenwrap "+ISAM " : redwrap "-ISAM " ;
	$engines .= (defined $myvar{'have_ndbcluster'} && $myvar{'have_ndbcluster'} eq "YES")? greenwrap "+NDBCluster " : redwrap "-NDBCluster " ;	
	print "$engines\n";
	my @tblist;
	# Now we build a database list, and loop through it to get storage engine stats for tables
	my @dblist = `mysql $mysqllogin -Bse "SHOW DATABASES"`;
	foreach my $db (@dblist) {
		chomp($db);
		if ($db eq "information_schema") { next; }
		if ($mysqlvermajor == 3 || ($mysqlvermajor == 4 && $mysqlverminor == 0)) {
			# MySQL 3.23/4.0 keeps Data_Length in the 6th column
			push (@tblist,`mysql $mysqllogin -Bse "SHOW TABLE STATUS FROM \\\`$db\\\`" | awk '{print \$2,\$6}'`);
		} else {
			# MySQL 4.1+ keeps Data_Length in the 7th column
			push (@tblist,`mysql $mysqllogin -Bse "SHOW TABLE STATUS FROM \\\`$db\\\`" | awk '{print \$2,\$7}'`);
		}
	}
	# Parse through the table list to generate storage engine counts/statistics
	foreach my $line (@tblist) {
		$line =~ /([a-zA-Z_]*)\s*(.*)/;
		my $engine = $1;
		my $size = $2;
		if ($size !~ /^\d+$/) { $size = 0; }
		if (defined $enginestats{$engine}) {
			$enginestats{$engine} += $size;
			$enginecount{$engine} += 1;
		} else {
			$enginestats{$engine} = $size;
			$enginecount{$engine} = 1;
		}
	}
	while (my ($engine,$size) = each(%enginestats)) {
		infoprint "Data in $engine tables: ".hr_bytes_rnd($size)." (Tables: ".$enginecount{$engine}.")"."\n";
	}
	# If the storage engine isn't being used, recommend it to be disabled
	if (!defined $enginestats{'InnoDB'} && defined $myvar{'have_innodb'} && $myvar{'have_innodb'} eq "YES") {
		badprint "InnoDB is enabled but isn't being used\n";
		push(@generalrec,"Add skip-innodb to MySQL configuration to disable InnoDB");
	}
	if (!defined $enginestats{'BDB'} && defined $myvar{'have_bdb'} && $myvar{'have_bdb'} eq "YES") {
		badprint "BDB is enabled but isn't being used\n";
		push(@generalrec,"Add skip-bdb to MySQL configuration to disable BDB");
	}
	if (!defined $enginestats{'ISAM'} && defined $myvar{'have_isam'} && $myvar{'have_isam'} eq "YES") {
		badprint "ISAM is enabled but isn't being used\n";
		push(@generalrec,"Add skip-isam to MySQL configuration to disable ISAM");
	}
}

my %mycalc;
sub calculations {
	if ($mystat{'Questions'} < 1) {
		badprint "Your server has not answered any queries - cannot continue...";
		exit 0;
	}
	# Per-thread memory
	if ($mysqlvermajor > 3) {
		$mycalc{'per_thread_buffers'} = $myvar{'read_buffer_size'} + $myvar{'read_rnd_buffer_size'} + $myvar{'sort_buffer_size'} + $myvar{'thread_stack'} + $myvar{'join_buffer_size'};
	} else {
		$mycalc{'per_thread_buffers'} = $myvar{'record_buffer'} + $myvar{'record_rnd_buffer'} + $myvar{'sort_buffer'} + $myvar{'thread_stack'} + $myvar{'join_buffer_size'};
	}
	$mycalc{'total_per_thread_buffers'} = $mycalc{'per_thread_buffers'} * $myvar{'max_connections'};
	$mycalc{'max_total_per_thread_buffers'} = $mycalc{'per_thread_buffers'} * $mystat{'Max_used_connections'};

	# Server-wide memory
	$mycalc{'max_tmp_table_size'} = ($myvar{'tmp_table_size'} > $myvar{'max_heap_table_size'}) ? $myvar{'max_heap_table_size'} : $myvar{'tmp_table_size'} ;
	$mycalc{'server_buffers'} = $myvar{'key_buffer_size'} + $mycalc{'max_tmp_table_size'};
	$mycalc{'server_buffers'} += (defined $myvar{'innodb_buffer_pool_size'}) ? $myvar{'innodb_buffer_pool_size'} : 0 ;
	$mycalc{'server_buffers'} += (defined $myvar{'innodb_additional_mem_pool_size'}) ? $myvar{'innodb_additional_mem_pool_size'} : 0 ;
	$mycalc{'server_buffers'} += (defined $myvar{'innodb_log_buffer_size'}) ? $myvar{'innodb_log_buffer_size'} : 0 ;
	$mycalc{'server_buffers'} += (defined $myvar{'query_cache_size'}) ? $myvar{'query_cache_size'} : 0 ;

	# Global memory
	$mycalc{'max_used_memory'} = $mycalc{'server_buffers'} + $mycalc{"max_total_per_thread_buffers"};
	$mycalc{'total_possible_used_memory'} = $mycalc{'server_buffers'} + $mycalc{'total_per_thread_buffers'};
	$mycalc{'pct_physical_memory'} = int(($mycalc{'total_possible_used_memory'} * 100) / $physical_memory);

	# Slow queries
	$mycalc{'pct_slow_queries'} = int(($mystat{'Slow_queries'}/$mystat{'Questions'}) * 100);
	
	# Connections
	$mycalc{'pct_connections_used'} = int(($mystat{'Max_used_connections'}/$myvar{'max_connections'}) * 100);
	$mycalc{'pct_connections_used'} = ($mycalc{'pct_connections_used'} > 100) ? 100 : $mycalc{'pct_connections_used'} ;
	
	# Key buffers
	if ($mysqlvermajor > 3 && !($mysqlvermajor == 4 && $mysqlverminor == 0)) {
		$mycalc{'pct_key_buffer_used'} = sprintf("%.1f",(1 - (($mystat{'Key_blocks_unused'} * $myvar{'key_cache_block_size'}) / $myvar{'key_buffer_size'})) * 100);
	}
	if ($mystat{'Key_read_requests'} > 0) {
		$mycalc{'pct_keys_from_mem'} = sprintf("%.1f",(100 - (($mystat{'Key_reads'} / $mystat{'Key_read_requests'}) * 100)));
	}
	$mycalc{'total_myisam_indexes'} = `find $myvar{'datadir'} -name '*.MYI' 2>&1 | xargs du -L $duflags '{}' 2>&1 | awk '{ s += \$1 } END { print s }'`;
	if ($mycalc{'total_myisam_indexes'} =~ /^0\n$/) { $mycalc{'total_myisam_indexes'} = "fail"; }
	chomp($mycalc{'total_myisam_indexes'});
	
	# Query cache
	if ($mysqlvermajor > 3) {
		$mycalc{'query_cache_efficiency'} = sprintf("%.1f",($mystat{'Qcache_hits'} / ($mystat{'Com_select'} + $mystat{'Qcache_hits'})) * 100);
		if ($myvar{'query_cache_size'}) {
			$mycalc{'pct_query_cache_used'} = sprintf("%.1f",100 - ($mystat{'Qcache_free_memory'} / $myvar{'query_cache_size'}) * 100);
		}
	if ($mystat{'Qcache_lowmem_prunes'} == 0) {
			$mycalc{'query_cache_prunes_per_day'} = 0;
		} else {
			$mycalc{'query_cache_prunes_per_day'} = int($mystat{'Qcache_lowmem_prunes'} / ($mystat{'Uptime'}/86400));
		}
	}
	
	# Sorting
	$mycalc{'total_sorts'} = $mystat{'Sort_scan'} + $mystat{'Sort_range'};
	if ($mycalc{'total_sorts'} > 0) {
		$mycalc{'pct_temp_sort_table'} = int(($mystat{'Sort_merge_passes'} / $mycalc{'total_sorts'}) * 100);
	}
	
	# Joins
	$mycalc{'joins_without_indexes'} = $mystat{'Select_range_check'} + $mystat{'Select_full_join'};
	$mycalc{'joins_without_indexes_per_day'} = int($mycalc{'joins_without_indexes'} / ($mystat{'Uptime'}/86400));
	
	# Temporary tables
	if ($mystat{'Created_tmp_tables'} > 0) {
		if ($mystat{'Created_tmp_disk_tables'} > 0) {
			$mycalc{'pct_temp_disk'} = int(($mystat{'Created_tmp_disk_tables'} / $mystat{'Created_tmp_tables'}) * 100);
		} else {
			$mycalc{'pct_temp_disk'} = 0;
		}
	}
	
	# Table cache
	if ($mystat{'Opened_tables'} > 0) {
		$mycalc{'table_cache_hit_rate'} = int($mystat{'Open_tables'}*100/$mystat{'Opened_tables'});
	} else {
		$mycalc{'table_cache_hit_rate'} = 100;
	}
	
	# Open files
	if ($mystat{'Open_files'} > 0 && $myvar{'open_files_limit'} > 0) {
		$mycalc{'pct_files_open'} = int($mystat{'Open_files'}*100/$myvar{'open_files_limit'});
	}
	
	# Table locks
	if ($mystat{'Table_locks_immediate'} > 0) {
		if ($mystat{'Table_locks_waited'} == 0) {
			$mycalc{'pct_table_locks_immediate'} = 100;
		} else {
			$mycalc{'pct_table_locks_immediate'} = int($mystat{'Table_locks_immediate'}*100/($mystat{'Table_locks_waited'} + $mystat{'Table_locks_immediate'}));
		}
	}
	
	# Thread cache
	$mycalc{'thread_cache_hit_rate'} = int(100 - (($mystat{'Threads_created'} / $mystat{'Connections'}) * 100));

	# Other
	if ($mystat{'Connections'} > 0) {
		$mycalc{'pct_aborted_connections'} = int(($mystat{'Aborted_connects'}/$mystat{'Connections'}) * 100);
	}
	if ($mystat{'Questions'} > 0) {
		$mycalc{'total_reads'} = $mystat{'Com_select'};
		$mycalc{'total_writes'} = $mystat{'Com_delete'} + $mystat{'Com_insert'} + $mystat{'Com_update'} + $mystat{'Com_replace'};
		if ($mycalc{'total_reads'} == 0) {
			$mycalc{'pct_reads'} = 0;
			$mycalc{'pct_writes'} = 100;
		} else {
			$mycalc{'pct_reads'} = int(($mycalc{'total_reads'}/($mycalc{'total_reads'}+$mycalc{'total_writes'})) * 100);
			$mycalc{'pct_writes'} = 100-$mycalc{'pct_reads'};
		}
	}

	# InnoDB
	if ($myvar{'have_innodb'} eq "YES") {
		$mycalc{'innodb_log_size_pct'} = ($myvar{'innodb_log_file_size'} * 100 / $myvar{'innodb_buffer_pool_size'});
	}
}

sub mysql_stats {
	print "\n-------- Performance Metrics -------------------------------------------------\n";
	# Show uptime, queries per second, connections, traffic stats
	my $qps;
	if ($mystat{'Uptime'} > 0) { $qps = sprintf("%.3f",$mystat{'Questions'}/$mystat{'Uptime'}); }
	if ($mystat{'Uptime'} < 86400) { push(@generalrec,"MySQL started within last 24 hours - recommendations may be inaccurate"); }
	infoprint "Up for: ".pretty_uptime($mystat{'Uptime'})." (".hr_num($mystat{'Questions'}).
		" q [".hr_num($qps)." qps], ".hr_num($mystat{'Connections'})." conn,".
		" TX: ".hr_num($mystat{'Bytes_sent'}).", RX: ".hr_num($mystat{'Bytes_received'}).")\n";
	infoprint "Reads / Writes: ".$mycalc{'pct_reads'}."% / ".$mycalc{'pct_writes'}."%\n";

	# Memory usage
	infoprint "Total buffers: ".hr_bytes($mycalc{'per_thread_buffers'})." per thread and ".hr_bytes($mycalc{'server_buffers'})." global\n";
	if ($mycalc{'total_possible_used_memory'} > 2*1024*1024*1024 && $arch eq 32) {
		badprint "Allocating > 2GB RAM on 32-bit systems can cause system instability\n";
		badprint "Maximum possible memory usage: ".hr_bytes($mycalc{'total_possible_used_memory'})." ($mycalc{'pct_physical_memory'}% of installed RAM)\n";
	} elsif ($mycalc{'pct_physical_memory'} > 85) {
		badprint "Maximum possible memory usage: ".hr_bytes($mycalc{'total_possible_used_memory'})." ($mycalc{'pct_physical_memory'}% of installed RAM)\n";
		push(@generalrec,"Reduce your overall MySQL memory footprint for system stability");
	} else {
		goodprint "Maximum possible memory usage: ".hr_bytes($mycalc{'total_possible_used_memory'})." ($mycalc{'pct_physical_memory'}% of installed RAM)\n";
	}
	
	# Slow queries
	if ($mycalc{'pct_slow_queries'} > 5) {
		badprint "Slow queries: $mycalc{'pct_slow_queries'}% (".hr_num($mystat{'Slow_queries'})."/".hr_num($mystat{'Questions'}).")\n";
	} else {
		goodprint "Slow queries: $mycalc{'pct_slow_queries'}% (".hr_num($mystat{'Slow_queries'})."/".hr_num($mystat{'Questions'}).")\n";
	}
	if ($myvar{'long_query_time'} > 10) { push(@adjvars,"long_query_time (<= 10)"); }
	if (defined($myvar{'log_slow_queries'})) {
		if ($myvar{'log_slow_queries'} eq "OFF") { push(@generalrec,"Enable the slow query log to troubleshoot bad queries"); }
	}
	
	# Connections
	if ($mycalc{'pct_connections_used'} > 85) {
		badprint "Highest connection usage: $mycalc{'pct_connections_used'}%  ($mystat{'Max_used_connections'}/$myvar{'max_connections'})\n";
		push(@adjvars,"max_connections (> ".$myvar{'max_connections'}.")");
		push(@adjvars,"wait_timeout (< ".$myvar{'wait_timeout'}.")","interactive_timeout (< ".$myvar{'interactive_timeout'}.")");
		push(@generalrec,"Reduce or eliminate persistent connections to reduce connection usage")
	} else {
		goodprint "Highest usage of available connections: $mycalc{'pct_connections_used'}% ($mystat{'Max_used_connections'}/$myvar{'max_connections'})\n";
	}
	
	# Key buffer
	if ($mycalc{'total_myisam_indexes'} =~ /^fail$/) { 
		badprint "Cannot calculate MyISAM index size - re-run script as root user\n";
	} elsif ($mycalc{'total_myisam_indexes'} == "0") {
		badprint "None of your MyISAM tables are indexed - add indexes immediately\n";
	} else {
		if ($myvar{'key_buffer_size'} < $mycalc{'total_myisam_indexes'} && $mycalc{'pct_keys_from_mem'} < 95) {
			badprint "Key buffer size / total MyISAM indexes: ".hr_bytes($myvar{'key_buffer_size'})."/".hr_bytes($mycalc{'total_myisam_indexes'})."\n";
			push(@adjvars,"key_buffer_size (> ".hr_bytes($mycalc{'total_myisam_indexes'}).")");
		} else {
			goodprint "Key buffer size / total MyISAM indexes: ".hr_bytes($myvar{'key_buffer_size'})."/".hr_bytes($mycalc{'total_myisam_indexes'})."\n";
		}
		if ($mystat{'Key_read_requests'} > 0) {
			if ($mycalc{'pct_keys_from_mem'} < 95) {
				badprint "Key buffer hit rate: $mycalc{'pct_keys_from_mem'}%\n";
			} else {
				goodprint "Key buffer hit rate: $mycalc{'pct_keys_from_mem'}%\n";
			}
		} else {
			# For the sake of space, we will be quiet here
			# No queries have run that would use keys
		}
	}
	
	# Query cache
	if ($mysqlvermajor < 4) { 
		# For the sake of space, we will be quiet here
		# MySQL versions < 4.01 don't support query caching
		push(@generalrec,"Upgrade MySQL to version 4+ to utilize query caching");
	} elsif ($myvar{'query_cache_size'} < 1) {
		badprint "Query cache is disabled\n";
		push(@adjvars,"query_cache_size (>= 8M)");
	} elsif ($mystat{'Com_select'} == 0) {
		badprint "Query cache cannot be analyzed - no SELECT statements executed\n";
	} else {
		if ($mycalc{'query_cache_efficiency'} < 20) {
			badprint "Query cache efficiency: $mycalc{'query_cache_efficiency'}%\n";
			push(@adjvars,"query_cache_limit (> 1M, or use smaller result sets)");
		} else {
			goodprint "Query cache efficiency: $mycalc{'query_cache_efficiency'}%\n";
		}
		if ($mycalc{'query_cache_prunes_per_day'} > 98) {
			badprint "Query cache prunes per day: $mycalc{'query_cache_prunes_per_day'}\n";
			push(@adjvars,"query_cache_size (> ".hr_bytes_rnd($myvar{'query_cache_size'}).")")
		} else {
			goodprint "Query cache prunes per day: $mycalc{'query_cache_prunes_per_day'}\n";
		}
	}
	
	# Sorting
	if ($mycalc{'total_sorts'} == 0) {
		# For the sake of space, we will be quiet here
		# No sorts have run yet
	} elsif ($mycalc{'pct_temp_sort_table'} > 10) {
		badprint "Sorts requiring temporary tables: $mycalc{'pct_temp_sort_table'}%\n";
		push(@adjvars,"sort_buffer_size (> ".hr_bytes_rnd($myvar{'sort_buffer_size'}).")");
		push(@adjvars,"read_rnd_buffer_size (> ".hr_bytes_rnd($myvar{'read_rnd_buffer_size'}).")");
	} else {
		goodprint "Sorts requiring temporary tables: $mycalc{'pct_temp_sort_table'}%\n";
	}
	
	# Joins
	if ($mycalc{'joins_without_indexes_per_day'} > 250) {
		badprint "Joins performed without indexes: $mycalc{'joins_without_indexes'}\n";
		push(@adjvars,"join_buffer_size (> ".hr_bytes($myvar{'join_buffer_size'}).", or always use indexes with joins)");
		push(@generalrec,"Adjust your join queries to always utilize indexes");
	} else {
		# For the sake of space, we will be quiet here
		# No joins have run without indexes
	}
	
	# Temporary tables
	if ($mystat{'Created_tmp_tables'} > 0) {
		if ($mycalc{'pct_temp_disk'} > 25 && $mycalc{'max_tmp_table_size'} < 256*1024*1024) {
			badprint "Temporary tables created on disk: $mycalc{'pct_temp_disk'}%\n";
			push(@adjvars,"tmp_table_size (> ".hr_bytes_rnd($myvar{'tmp_table_size'}).")");
			push(@adjvars,"max_heap_table_size (> ".hr_bytes_rnd($myvar{'max_heap_table_size'}).")");
			push(@generalrec,"Be sure that tmp_table_size/max_heap_table_size are equal");
			push(@generalrec,"Reduce your SELECT DISTINCT queries without LIMIT clauses");
		} elsif ($mycalc{'pct_temp_disk'} > 25 && $mycalc{'max_tmp_table_size'} >= 256) {
			badprint "Temporary tables created on disk: $mycalc{'pct_temp_disk'}%\n";
			push(@generalrec,"Temporary table size is already large - reduce result set size");
			push(@generalrec,"Reduce your SELECT DISTINCT queries without LIMIT clauses");
		} else {
			goodprint "Temporary tables created on disk: $mycalc{'pct_temp_disk'}%\n";
		}
	} else {
		# For the sake of space, we will be quiet here
		# No temporary tables have been created
	}

	# Thread cache
	if ($myvar{'thread_cache_size'} eq 0) {
		badprint "Thread cache is disabled\n";
		push(@generalrec,"Set thread_cache_size to 4 as a starting value");
		push(@adjvars,"thread_cache_size (start at 4)");
	} else {
		if ($mycalc{'thread_cache_hit_rate'} <= 50) {
			badprint "Thread cache hit rate: $mycalc{'thread_cache_hit_rate'}%\n";
			push(@adjvars,"thread_cache_size (> $myvar{'thread_cache_size'})");
		} else {
			goodprint "Thread cache hit rate: $mycalc{'thread_cache_hit_rate'}%\n";
		}
	}

	# Table cache
	if ($mystat{'Open_tables'} > 0) {
		if ($mycalc{'table_cache_hit_rate'} < 20) {
			badprint "Table cache hit rate: $mycalc{'table_cache_hit_rate'}%\n";
			push(@adjvars,"table_cache (> ".$myvar{'table_cache'}.")");
			push(@generalrec,"Increase table_cache gradually to avoid file descriptor limits");
		} else {
			goodprint "Table cache hit rate: $mycalc{'table_cache_hit_rate'}%\n";
		}
	}

	# Open files
	if ($myvar{'open_files_limit'} > 0) {
		if ($mycalc{'pct_files_open'} > 85) {
			badprint "Open file limit used: $mycalc{'pct_files_open'}%\n";
			push(@adjvars,"open_files_limit (> ".$myvar{'open_files_limit'}.")");
		} else {
			goodprint "Open file limit used: $mycalc{'pct_files_open'}%\n";
		}
	}

	# Table locks
	if (defined $mycalc{'pct_table_locks_immediate'}) {
		if ($mycalc{'pct_table_locks_immediate'} < 95) {
			badprint "Table locks acquired immediately: $mycalc{'pct_table_locks_immediate'}%\n";
			push(@generalrec,"Optimize queries and/or use InnoDB to reduce lock wait");
		} else {
			goodprint "Table locks acquired immediately: $mycalc{'pct_table_locks_immediate'}%\n";
		}
	}

	# Performance options
	if ($mysqlvermajor == 3 || ($mysqlvermajor == 4 && $mysqlverminor == 0)) {
		push(@generalrec,"Upgrade to MySQL 4.1+ to use concurrent MyISAM inserts");
	} elsif ($myvar{'concurrent_insert'} eq "OFF") {
		push(@generalrec,"Enable concurrent_insert by setting it to 'ON'");
	} elsif ($myvar{'concurrent_insert'} eq 0) {
		push(@generalrec,"Enable concurrent_insert by setting it to 1");
	}
	if ($mycalc{'pct_aborted_connections'} > 5) {
		badprint "Connections aborted: ".$mycalc{'pct_aborted_connections'}."%\n";
		push(@generalrec,"Your applications are not closing MySQL connections properly");
	}
	
	# InnoDB
	if (defined $myvar{'have_innodb'} && $myvar{'have_innodb'} eq "YES" && defined $enginestats{'InnoDB'}) {
		if ($myvar{'innodb_buffer_pool_size'} > $enginestats{'InnoDB'}) {
			goodprint "InnoDB data size / buffer pool: ".hr_bytes($enginestats{'InnoDB'})."/".hr_bytes($myvar{'innodb_buffer_pool_size'})."\n";
		} else {
			badprint "InnoDB data size / buffer pool: ".hr_bytes($enginestats{'InnoDB'})."/".hr_bytes($myvar{'innodb_buffer_pool_size'})."\n";
			push(@adjvars,"innodb_buffer_pool_size (>= ".hr_bytes_rnd($enginestats{'InnoDB'}).")");
		}
	}
}

# Take the two recommendation arrays and display them at the end of the output
sub make_recommendations {
	print "\n-------- Recommendations -----------------------------------------------------\n";
	if (@generalrec > 0) {
		print "General recommendations:\n";
		foreach (@generalrec) { print "    ".$_."\n"; }
	}
	if (@adjvars > 0) {
		print "Variables to adjust:\n";
		if ($mycalc{'pct_physical_memory'} > 85) {
			print "  *** MySQL's maximum memory usage exceeds your installed memory ***\n".
				"  *** Add more RAM before increasing any MySQL buffer variables  ***\n";
		}
		foreach (@adjvars) { print "    ".$_."\n"; }
	}
	if (@generalrec == 0 && @adjvars ==0) {
		print "No additional performance recommendations are available.\n"
	}
	print "\n";
}

# ---------------------------------------------------------------------------
# BEGIN 'MAIN'
# ---------------------------------------------------------------------------
print	"\n >>  MySQLTuner $tunerversion - Major Hayden <major\@mhtx.net>\n".
		" >>  Bug reports, feature requests, and downloads at http://mysqltuner.com/\n".
		" >>  Run with '--help' for additional options and output filtering\n";
os_setup;						# Set up some OS variables
mysql_setup;					# Gotta login first
get_all_vars;					# Toss variables/status into hashes
validate_mysql_version;			# Check current MySQL version
check_architecture;				# Suggest 64-bit upgrade
check_storage_engines;			# Show enabled storage engines
calculations;					# Calculate everything we need
mysql_stats;					# Print the server stats
make_recommendations;			# Make recommendations based on stats
# ---------------------------------------------------------------------------
# END 'MAIN'
# ---------------------------------------------------------------------------

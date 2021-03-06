# =======================
# keepPreserveSkill v0.9.7 beta
# =======================
# This plugin is licensed under the GNU GPL
# Created by Henrybk
#
# What it does: tries to keep your copied skill from being lost
#
#
# Example (put in config.txt):
#	
#	Config example:
#	keepPreserveSkill_on 1 (boolean active/inactive)
#	keepPreserveSkill_handle MG_COLDBOLT (handle of skill to be kept)
#	keepPreserveSkill_timeout 450 (amount of seconds after we used preserve in which we will start to try to use it again while walking, taking items, routing, etc)
#	keepPreserveSkill_timeoutCritical 550 (same as above, but after this time we will try to use it even while attacking)
#
#
# Extras: The plugin will make the character try to teleport if there is a monster on screen and you don't have preserve activated, this can make you keep teleport forever on very mobbed maps like juperus.

package keepPreserveSkill;

use Plugins;
use Globals;
use Log qw(message warning error debug);
use File::Spec;
use JSON::Tiny qw(from_json to_json);
use AI;
use Misc;
use Network;
use Network::Send;
use Utils;
use Commands;
use Actor;

use constant {
	INACTIVE => 0,
	ACTIVE => 1
};

Plugins::register('keepPreserveSkill', 'Tries to not get the preserved skill lost', , \&on_unload, \&on_unload);

my $base_hooks = Plugins::addHooks(
	['start3',        \&on_start3],
	['postloadfiles', \&checkConfig],
	['configModify',  \&on_configModify]
);

our $folder = $Plugins::current_plugin_folder;

my $status = INACTIVE;

my $plugin_name = "keepPreserveSkill";

our %mobs;
my $in_game_hook = undef;
my $last_preserve_use_time;
my $keeping_hooks;
my $keep_skill;
my $preserve_skill;

sub on_unload {
   Plugins::delHook($base_hooks);
   changeStatus(INACTIVE);
   message "[$plugin_name] Plugin unloading or reloading.\n", 'success';
}

sub on_start3 {
	$preserve_skill = new Skill(handle => 'ST_PRESERVE');
	my $file = File::Spec->catdir($folder,'mobs_info.json');
    %mobs = %{loadFile($file)};
	if (!%mobs || scalar keys %mobs == 0) {
		error "[$plugin_name] Could not load mobs info due to a file loading problem.\n".
		      "[$plugin_name] File which was not loaded: $file.\n";
		return;
	}
	Log::message( sprintf "[%s] Found %d mobs.\n", $plugin_name, scalar keys %mobs );
}

sub loadFile {
    my $file = shift;

	return unless (open FILE, "<:utf8", $file);
	my @lines = <FILE>;
	close(FILE);
	chomp @lines;
	my $jsonString = join('',@lines);

	my %converted = %{from_json($jsonString, { utf8  => 1 } )};

	return \%converted;
}

sub checkConfig {
	if (validate_settings()) {
		changeStatus(ACTIVE);
	} else {
		changeStatus(INACTIVE);
	}
}

sub on_configModify {
	my (undef, $args) = @_;
	return unless ($args->{key} eq 'keepPreserveSkill_on' || $args->{key} eq 'keepPreserveSkill_handle' || $args->{key} eq 'keepPreserveSkill_timeout' || $args->{key} eq 'keepPreserveSkill_timeoutCritical');
	if (validate_settings($args->{key}, $args->{val})) {
		changeStatus(ACTIVE);
	} else {
		changeStatus(INACTIVE);
	}
}

sub validate_settings {
	my ($key, $val) = @_;
	
	my $on_off;
	my $handle;
	my $timeout;
	my $timeoutCritical;
	if (!defined $key) {
		$on_off = $config{keepPreserveSkill_on};
		$handle = $config{keepPreserveSkill_handle};
		$timeout = $config{keepPreserveSkill_timeout};
		$timeoutCritical = $config{keepPreserveSkill_timeoutCritical};
	} else {
		$on_off =           ($key eq 'keepPreserveSkill_on'              ?   $val : $config{keepPreserveSkill_on});
		$handle =           ($key eq 'keepPreserveSkill_handle'          ?   $val : $config{keepPreserveSkill_handle});
		$timeout =          ($key eq 'keepPreserveSkill_timeout'         ?   $val : $config{keepPreserveSkill_timeout});
		$timeoutCritical =  ($key eq 'keepPreserveSkill_timeoutCritical' ?   $val : $config{keepPreserveSkill_timeoutCritical});
	}
	
	my $error = 0;
	if (!defined $on_off || !defined $handle || !defined $timeout || !defined $timeoutCritical) {
		message "[$plugin_name] There are config keys not defined.\n","system";
		$error = 1;
		
	} elsif ($on_off !~ /^[01]$/) {
		message "[$plugin_name] Value of key 'keepPreserveSkill_on' must be 0 or 1.\n","system";
		$error = 1;
		
	} elsif ($timeout !~ /^\d+$/) {
		message "[$plugin_name] Value of key 'keepPreserveSkill_timeout' must be a number.\n","system";
		$error = 1;
		
	} elsif ($timeoutCritical !~ /^\d+$/) {
		message "[$plugin_name] Value of key 'keepPreserveSkill_timeoutCritical' must be a number.\n","system";
		$error = 1;
	}
	
	if ($error == 1) {
		configModify('keepPreserveSkill_on', 0) if (defined $on_off && $on_off != 0);
		return 0;
	}
	
	return 0 unless ($on_off == 1);
	
	$keep_skill = new Skill(handle => $handle);
	
	if ($char && $net && $net->getState() == Network::IN_GAME) {
		unless (check_skills()) {
			configModify('keepPreserveSkill_on', 0);
			return 0;
		}
		
	} else {
		if (!defined $in_game_hook) {
			$in_game_hook = Plugins::addHooks(
				['in_game',  \&on_in_game]
			);
		}
		return 0;
	}
	
	return 1;
}

sub on_in_game {
	if (check_skills()) {
		changeStatus(ACTIVE);
	} else {
		configModify('keepPreserveSkill_on', 0);
		changeStatus(INACTIVE);
	}
	Plugins::delHook($in_game_hook);
	undef $in_game_hook;
}

sub check_skills {
	if (!$char->getSkillLevel($preserve_skill)) {
		message "[$plugin_name] You don't have the skill Preserve\n","system";
		return 0;
		
	} elsif (!$char->getSkillLevel($keep_skill)) {
		message "[$plugin_name] You don't have the skill you want to keep: ".$keep_skill->getName."\n","system";
		return 0;
	}
	
	return 1;
}

sub changeStatus {
	my $new_status = shift;
	
	return if ($new_status == $status);
	
	if ($new_status == INACTIVE) {
		Plugins::delHook($keeping_hooks);
		debug "[$plugin_name] Plugin stage changed to 'INACTIVE'\n", "$plugin_name", 1;
		
	} elsif ($new_status == ACTIVE) {
		$keeping_hooks = Plugins::addHooks(
			['AI_pre',\&on_AI_pre, undef],
			['Actor::setStatus::change',\&on_statusChange, undef],
			['packet/skill_update',\&on_skills_update, undef],
			['packet/skills_list',\&on_skills_update, undef],
			['packet/skill_add',\&on_skills_update, undef],
			['packet/skill_delete',\&on_skills_update, undef]
		);
		debug "[$plugin_name] Plugin stage changed to 'ACTIVE'\n", "$plugin_name", 1;
	}
	
	$status = $new_status;
}

######

sub on_statusChange {
	my (undef, $args) = @_;
	if ($args->{handle} eq 'EFST_PRESERVE' && $args->{actor_type}->isa('Actor::You') && $args->{flag} == 1) {
		message "[$plugin_name] Preserve was used, reseting timer\n","system";
		$last_preserve_use_time = time;
	}
}

sub on_skills_update {
	unless (check_skills()) {
		error "[$plugin_name] You lost the skill you want to keep or the preserve skill. Deactivating plugin.\n.";
		configModify('keepPreserveSkill_on', 0);
		changeStatus(INACTIVE);
	}
}

sub on_AI_pre {
	return if (!$char || !$net || $net->getState() != Network::IN_GAME);
	return if ($char->{muted});
	return if ($char->{casting});
	return if ($char->statusActive('EFST_POSTDELAY'));
	
	if ($char->statusActive('EFST_PRESERVE')) {
		return unless (timeOut($config{keepPreserveSkill_timeout}, $last_preserve_use_time));
		my $timeout_reuse = ($last_preserve_use_time + $config{keepPreserveSkill_timeout} - time);
		if (AI::isIdle || AI::is(qw(mapRoute follow sitAuto take sitting clientSuspend move route items_take items_gather))) {
			message "[$plugin_name] Using non-critical preserve with ".$timeout_reuse." seconds left on counter\n","system";
			Commands::run("ss 475 1");
			return;
		}
		
		return unless (timeOut($config{keepPreserveSkill_timeoutCritical}, $last_preserve_use_time));
		$timeout_reuse = ($last_preserve_use_time + $config{keepPreserveSkill_timeoutCritical} - time);
		if (AI::is(qw(attack))) {
			message "[$plugin_name] Using critical preserve with ".$timeout_reuse." seconds left on counter\n","system";
			Commands::run("ss 475 1");
			return;
		}
		
	} else {
		my $teleport = 0;
		if (ai_getAggressives()) {
			message "[$plugin_name] A monster is attacking us, teleporting to not lose skill\n","system";
			$teleport = 1;
			
		} elsif (scalar @{$monstersList->getItems()} > 0) {
			foreach my $mob (@{$monstersList->getItems()}) {
				my $id = $mob->{nameID};
				my $mob_info = $mobs{$id};
				next unless ($mob_info->{is_aggressive} == 1);
				message "[$plugin_name] Aggressive monster near, teleporting to not lose skill\n","system";
				$teleport = 1;
				last;
			}
		}
		if ($teleport == 1) {
			if (main::useTeleport(1)) {
				message "[$plugin_name] Teleport sent.\n", "info";
			} else {
				message "[$plugin_name] Cannot use teleport.\n", "info";
			}
		} else {
			message "[$plugin_name] Using preserve skill\n","system";
			Commands::run("ss 475 1");
		}
	}
}

return 1;
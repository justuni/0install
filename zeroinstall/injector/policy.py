"""
Chooses a set of implementations based on a policy.

@deprecated: see L{solver}
"""

# Copyright (C) 2008, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import time
import sys, os, sets
from logging import info, debug, warn
import arch

from model import *
from namespaces import *
import ConfigParser
from zeroinstall.support import tasks, basedir
from zeroinstall.injector.iface_cache import iface_cache, PendingFeed
from zeroinstall.injector.trust import trust_db

# If we started a check within this period, don't start another one:
FAILED_CHECK_DELAY = 60 * 60	# 1 Hour

class Policy(object):
	"""Chooses a set of implementations based on a policy.
	Typical use:
	 1. Create a Policy object, giving it the URI of the program to be run and a handler.
	 2. Call L{recalculate}. If more information is needed, the handler will be used to download it.
	 3. When all downloads are complete, the L{implementation} map contains the chosen versions.
	 4. Use L{get_uncached_implementations} to find where to get these versions and download them
	    using L{begin_impl_download}.

	@ivar root: URI of the root interface
	@ivar implementation: chosen implementations
	@type implementation: {model.Interface: model.Implementation or None}
	@ivar watchers: callbacks to invoke after recalculating
	@ivar help_with_testing: default stability policy
	@type help_with_testing: bool
	@ivar network_use: one of the model.network_* values
	@ivar freshness: seconds allowed since last update
	@type freshness: int
	@ivar ready: whether L{implementation} is complete enough to run the program
	@type ready: bool
	@ivar handler: handler for main-loop integration
	@type handler: L{handler.Handler}
	@ivar src: whether we are looking for source code
	@type src: bool
	@ivar stale_feeds: set of feeds which are present but haven't been checked for a long time
	@type stale_feeds: set
	"""
	__slots__ = ['root', 'watchers',
		     'freshness', 'handler', '_warned_offline',
		     'src', 'stale_feeds', 'solver', '_fetcher']
	
	help_with_testing = property(lambda self: self.solver.help_with_testing,
				     lambda self, value: setattr(self.solver, 'help_with_testing', value))

	network_use = property(lambda self: self.solver.network_use,
				     lambda self, value: setattr(self.solver, 'network_use', value))

	implementation = property(lambda self: self.solver.selections)

	ready = property(lambda self: self.solver.ready)

	def __init__(self, root, handler = None, src = False):
		"""
		@param root: The URI of the root interface (the program we want to run).
		@param handler: A handler for main-loop integration.
		@type handler: L{zeroinstall.injector.handler.Handler}
		@param src: Whether we are looking for source code.
		@type src: bool
		"""
		self.watchers = []
		self.freshness = 60 * 60 * 24 * 30
		self.src = src				# Root impl must be a "src" machine type
		self.stale_feeds = sets.Set()

		from zeroinstall.injector.solver import DefaultSolver
		self.solver = DefaultSolver(network_full, iface_cache, iface_cache.stores)

		# If we need to download something but can't because we are offline,
		# warn the user. But only the first time.
		self._warned_offline = False
		self._fetcher = None

		# (allow self for backwards compat)
		self.handler = handler or self

		debug("Supported systems: '%s'", arch.os_ranks)
		debug("Supported processors: '%s'", arch.machine_ranks)

		path = basedir.load_first_config(config_site, config_prog, 'global')
		if path:
			try:
				config = ConfigParser.ConfigParser()
				config.read(path)
				self.solver.help_with_testing = config.getboolean('global',
								'help_with_testing')
				self.solver.network_use = config.get('global', 'network_use')
				self.freshness = int(config.get('global', 'freshness'))
				assert self.solver.network_use in network_levels
			except Exception, ex:
				warn("Error loading config: %s", ex)

		self.set_root(root)

	@property
	def fetcher(self):
		if not self._fetcher:
			import fetch
			self._fetcher = fetch.Fetcher(self.handler)
		return self._fetcher
	
	def set_root(self, root):
		"""Change the root interface URI."""
		assert isinstance(root, (str, unicode))
		self.root = root
		for w in self.watchers: w()

	def save_config(self):
		"""Write global settings."""
		config = ConfigParser.ConfigParser()
		config.add_section('global')

		config.set('global', 'help_with_testing', self.help_with_testing)
		config.set('global', 'network_use', self.network_use)
		config.set('global', 'freshness', self.freshness)

		path = basedir.save_config_path(config_site, config_prog)
		path = os.path.join(path, 'global')
		config.write(file(path + '.new', 'w'))
		os.rename(path + '.new', path)
	
	def recalculate(self, fetch_stale_interfaces = True):
		"""Deprecated.
		@see: L{solve_with_downloads}
		"""

		self.stale_feeds = sets.Set()

		host_arch = arch.get_host_architecture()
		if self.src:
			host_arch = arch.SourceArchitecture(host_arch)
		self.solver.solve(self.root, host_arch)

		if self.network_use == network_offline:
			fetch_stale_interfaces = False

		blockers = []
		for f in self.solver.feeds_used:
			if f.startswith('/'): continue
			feed = iface_cache.get_feed(f)
			if feed is None or feed.last_modified is None:
				self.download_and_import_feed_if_online(f)	# Will start a download
			elif self.is_stale(feed):
				debug("Adding %s to stale set", f)
				self.stale_feeds.add(iface_cache.get_interface(f))	# Legacy API
				if fetch_stale_interfaces:
					self.download_and_import_feed_if_online(f)	# Will start a download

		for w in self.watchers: w()

		return blockers
	
	def usable_feeds(self, iface):
		"""Generator for C{iface.feeds} that are valid for our architecture.
		@rtype: generator
		@see: L{arch}"""
		if self.src and iface.uri == self.root:
			# Note: when feeds are recursive, we'll need a better test for root here
			machine_ranks = {'src': 1}
		else:
			machine_ranks = arch.machine_ranks
			
		for f in iface.feeds:
			if f.os in arch.os_ranks and f.machine in machine_ranks:
				yield f
			else:
				debug("Skipping '%s'; unsupported architecture %s-%s",
					f, f.os, f.machine)

	def is_stale(self, feed):
		"""Check whether feed needs updating, based on the configured L{freshness}.
		None is considered to be stale.
		@return: true if feed is stale or missing."""
		if feed is None:
			return True
		if feed.url.startswith('/'):
			return False		# Local feeds are never stale
		if feed.last_modified is None:
			return True		# Don't even have it yet
		now = time.time()
		staleness = now - (feed.last_checked or 0)
		debug("Staleness for %s is %.2f hours", feed, staleness / 3600.0)

		if self.freshness == 0 or staleness < self.freshness:
			return False		# Fresh enough for us

		last_check_attempt = iface_cache.get_last_check_attempt(feed.url)
		if last_check_attempt and last_check_attempt > now - FAILED_CHECK_DELAY:
			debug("Stale, but tried to check recently (%s) so not rechecking now.", time.ctime(last_check_attempt))
			return False

		return True
	
	def download_and_import_feed_if_online(self, feed_url):
		"""If we're online, call L{download_and_import_feed}. Otherwise, log a suitable warning."""
		if self.network_use != network_offline:
			debug("Feed %s not cached and not off-line. Downloading...", feed_url)
			return self.fetcher.download_and_import_feed(feed_url, iface_cache)
		else:
			if self._warned_offline:
				debug("Not downloading feed '%s' because we are off-line.", feed_url)
			elif feed_url == injector_gui_uri:
				# Don't print a warning, because we always switch to off-line mode to
				# run the GUI the first time.
				info("Not downloading GUI feed '%s' because we are in off-line mode.", feed_url)
			else:
				warn("Not downloading feed '%s' because we are in off-line mode.", feed_url)
				self._warned_offline = True

	def get_implementation_path(self, impl):
		"""Return the local path of impl.
		@rtype: str
		@raise zeroinstall.zerostore.NotStored: if it needs to be added to the cache first."""
		assert isinstance(impl, Implementation)
		if impl.id.startswith('/'):
			return impl.id
		return iface_cache.stores.lookup(impl.id)

	def get_implementation(self, interface):
		"""Get the chosen implementation.
		@type interface: Interface
		@rtype: L{model.Implementation}
		@raise SafeException: if interface has not been fetched or no implementation could be
		chosen."""
		assert isinstance(interface, Interface)

		if not interface.name and not interface.feeds:
			raise SafeException("We don't have enough information to "
					    "run this program yet. "
					    "Need to download:\n%s" % interface.uri)
		try:
			return self.implementation[interface]
		except KeyError, ex:
			if interface.implementations:
				offline = ""
				if self.network_use == network_offline:
					offline = "\nThis may be because 'Network Use' is set to Off-line."
				raise SafeException("No usable implementation found for '%s'.%s" %
						(interface.name, offline))
			raise ex

	def get_cached(self, impl):
		"""Check whether an implementation is available locally.
		@type impl: model.Implementation
		@rtype: bool
		"""
		if isinstance(impl, DistributionImplementation):
			return impl.installed
		if impl.id.startswith('/'):
			return os.path.exists(impl.id)
		else:
			try:
				path = self.get_implementation_path(impl)
				assert path
				return True
			except:
				pass # OK
		return False
	
	def get_uncached_implementations(self):
		"""List all chosen implementations which aren't yet available locally.
		@rtype: [(str, model.Implementation)]"""
		uncached = []
		for iface in self.solver.selections:
			impl = self.solver.selections[iface]
			assert impl, self.solver.selections
			if not self.get_cached(impl):
				uncached.append((iface, impl))
		return uncached
	
	def refresh_all(self, force = True):
		"""Start downloading all feeds for all selected interfaces.
		@param force: Whether to restart existing downloads."""
		return self.solve_with_downloads(force = True)
	
	def get_feed_targets(self, feed_iface_uri):
		"""Return a list of Interfaces for which feed_iface can be a feed.
		This is used by B{0launch --feed}.
		@rtype: [model.Interface]
		@raise SafeException: If there are no known feeds."""
		# TODO: what if it isn't cached yet?
		feed_iface = iface_cache.get_interface(feed_iface_uri)
		if not feed_iface.feed_for:
			if not feed_iface.name:
				raise SafeException("Can't get feed targets for '%s'; failed to load interface." %
						feed_iface_uri)
			raise SafeException("Missing <feed-for> element in '%s'; "
					"this interface can't be used as a feed." % feed_iface_uri)
		feed_targets = feed_iface.feed_for
		debug("Feed targets: %s", feed_targets)
		if not feed_iface.name:
			warn("Warning: unknown interface '%s'" % feed_iface_uri)
		return [iface_cache.get_interface(uri) for uri in feed_targets]
	
	@tasks.async
	def solve_with_downloads(self, force = False):
		"""Run the solver, then download any feeds that are missing or
		that need to be updated. Each time a new feed is imported into
		the cache, the solver is run again, possibly adding new downloads.
		@param force: whether to download even if we're already ready to run."""
		
		downloads_finished = set()		# Successful or otherwise
		downloads_in_progress = {}		# URL -> Download

		host_arch = arch.get_host_architecture()
		if self.src:
			host_arch = arch.SourceArchitecture(host_arch)

		while True:
			self.solver.solve(self.root, host_arch)
			for w in self.watchers: w()

			if self.solver.ready and not force:
				break
			else:
				# Once we've starting downloading some things,
				# we might as well get them all.
				force = True

			if not self.network_use == network_offline:
				for f in self.solver.feeds_used:
					if f in downloads_finished or f in downloads_in_progress:
						continue
					if f.startswith('/'):
						continue
					feed = iface_cache.get_interface(f)
					downloads_in_progress[f] = self.fetcher.download_and_import_feed(f, iface_cache)

			if not downloads_in_progress:
				break

			blockers = downloads_in_progress.values()
			yield blockers
			tasks.check(blockers)

			for f in downloads_in_progress.keys():
				if downloads_in_progress[f].happened:
					del downloads_in_progress[f]
					downloads_finished.add(f)

	def need_download(self):
		"""Decide whether we need to download anything (but don't do it!)
		@return: true if we MUST download something (feeds or implementations)
		@rtype: bool"""
		host_arch = arch.get_host_architecture()
		if self.src:
			host_arch = arch.SourceArchitecture(host_arch)
		self.solver.solve(self.root, host_arch)
		for w in self.watchers: w()

		if not self.solver.ready:
			return True		# Maybe a newer version will work?
		
		if self.get_uncached_implementations():
			return True

		return False
	
	def download_uncached_implementations(self):
		"""Download all implementations chosen by the solver that are missing from the cache."""
		assert self.solver.ready, "Solver is not ready!\n%s" % self.solver.selections
		return self.fetcher.download_impls([impl for impl in self.solver.selections.values() if not self.get_cached(impl)],
						   iface_cache.stores)

	def download_icon(self, interface, force = False):
		"""Download an icon for this interface and add it to the
		icon cache. If the interface has no icon or we are offline, do nothing.
		@return: the task doing the import, or None
		@rtype: L{tasks.Task}"""
		debug("download_icon %s (force = %d)", interface, force)

		if self.network_use == network_offline:
			info("No icon present for %s, but off-line so not downloading", interface)
			return

		return self.fetcher.download_icon(interface, force)
	
	def get_interface(self, uri):
		"""@deprecated: use L{IfaceCache.get_interface} instead"""
		warn("Policy.get_interface is deprecated!")
		return iface_cache.get_interface(uri)

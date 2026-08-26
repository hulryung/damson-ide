import Foundation

/// One bounded file operation over ssh.
///
/// Bytes never travel as a decoded String. The far-side helper speaks an ASCII
/// protocol (`ORCHARD-FILE/1`) and base64-encodes names and file bodies, so a
/// Latin-1 file cannot become U+FFFD just because OpenSSH's stdout was parsed as
/// UTF-8. Classification of those bytes as text still happens *here*, through
/// `FileService.preview(data:)` / `FileService.text(of:)`.
struct RemoteFileTransport: Sendable {
    let runner: SSHRunner
    let root: String

    init(runner: SSHRunner, root: String) throws {
        self.runner = runner
        self.root = try RemoteFilePath.requireAbsoluteRoot(root)
    }

    var hostName: String { runner.hostName }

    func readDir(relativePath: String, showDotfiles: Bool) async throws -> [FileDirEntry] {
        let rel = try RemoteFilePath.requireSafe(relativePath)
        let parsed = try await run(op: "read-dir", relativePath: rel, extra: [
            "ORCHARD_FILE_DOTS": showDotfiles ? "1" : "0",
        ])
        var entries: [FileDirEntry] = []
        for record in parsed.records {
            guard case .entry(let kind, let name) = record else { continue }
            entries.append(FileDirEntry(name: name,
                                        isDirectory: kind == "d",
                                        isSymlink: kind == "l"))
        }
        entries.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return entries
    }

    func stat(relativePath: String) async throws -> FileStatInfo {
        let rel = try RemoteFilePath.requireSafe(relativePath)
        let parsed = try await run(op: "stat", relativePath: rel)
        guard let info = parsed.stat else {
            throw FileServiceError.unreadable(rel.isEmpty ? "." : rel)
        }
        return info
    }

    /// File bytes, exactly as they sit on the far side, subject to `maxBytes`.
    func readData(relativePath: String, maxBytes: Int) async throws -> (stat: FileStatInfo, data: Data) {
        let rel = try RemoteFilePath.requireSafe(relativePath)
        let parsed = try await run(op: "read", relativePath: rel, extra: [
            "ORCHARD_FILE_MAX": String(max(1, maxBytes)),
        ])
        guard let info = parsed.stat else {
            throw FileServiceError.unreadable(rel)
        }
        if info.isDirectory { throw FileServiceError.notAFile }
        guard let data = parsed.body else {
            throw FileServiceError.unreadable(rel)
        }
        if data.count > maxBytes { throw FileServiceError.fileTooLarge }
        return (info, data)
    }

    func list(query: String?, showDotfiles: Bool, limit: Int) async throws -> FileListResult {
        let cap = max(1, limit)
        var extra: [String: String] = [
            "ORCHARD_FILE_DOTS": showDotfiles ? "1" : "0",
            "ORCHARD_FILE_LIMIT": String(cap),
        ]
        if let query, !query.isEmpty { extra["ORCHARD_FILE_QUERY"] = query }
        let parsed = try await run(op: "list", relativePath: "", extra: extra)
        var files: [String] = []
        var total = parsed.total ?? 0
        for record in parsed.records {
            if case .list(let path) = record { files.append(path) }
        }
        files.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        if total == 0 { total = files.count }
        if files.count > cap { files = Array(files.prefix(cap)) }
        return FileListResult(files: files, totalCount: total, truncated: total > files.count)
    }

    func contentSearch(query: String, options: FileContentSearchOptions) async throws -> FileContentSearchResult {
        let include = try options.include.map(FileGlob.init)
        let exclude = try options.exclude.map(FileGlob.init)
        var extra: [String: String] = [
            "ORCHARD_FILE_QUERY": query,
            "ORCHARD_FILE_DOTS": options.showDotfiles ? "1" : "0",
            "ORCHARD_FILE_CASE": options.caseSensitive ? "1" : "0",
            "ORCHARD_FILE_LIMIT": String(max(1, options.limit)),
            "ORCHARD_FILE_PERFILE": String(max(1, options.perFileLimit)),
            "ORCHARD_FILE_FILEBUDGET": String(max(1, options.fileByteBudget)),
            "ORCHARD_FILE_TOTALBUDGET": String(max(1, options.totalByteBudget)),
            "ORCHARD_FILE_EXCERPT": String(max(16, options.maxExcerptLength)),
        ]
        if !include.isEmpty {
            extra["ORCHARD_FILE_INCLUDE_RE"] = include.map(\.regexPattern).joined(separator: "\n")
        }
        if !exclude.isEmpty {
            extra["ORCHARD_FILE_EXCLUDE_RE"] = exclude.map(\.regexPattern).joined(separator: "\n")
        }
        let parsed = try await run(op: "search", relativePath: "", extra: extra)
        var matches: [FileContentHit] = []
        for record in parsed.records {
            if case .hit(let path, let line, let excerpt) = record {
                matches.append(FileContentHit(path: path, line: line, excerpt: excerpt))
            }
        }
        matches.sort { a, b in
            let pathOrder = a.path.localizedStandardCompare(b.path)
            if pathOrder != .orderedSame { return pathOrder == .orderedAscending }
            return a.line < b.line
        }
        let cap = max(1, options.limit)
        var truncated = parsed.truncated
        if matches.count > cap {
            matches = Array(matches.prefix(cap))
            truncated = true
        }
        return FileContentSearchResult(matches: matches, totalCount: matches.count,
                                       truncated: truncated)
    }

    // MARK: - Run + parse

    func run(op: String, relativePath: String, extra: [String: String] = [:]) async throws -> Parsed {
        var env: [String: String] = [
            "ORCHARD_FILE_OP": op,
            "ORCHARD_FILE_ROOT": root,
            "ORCHARD_FILE_REL": relativePath,
        ]
        extra.forEach { env[$0] = $1 }
        let assigns = env.keys.sorted().map { key in
            "\(key)=\(SSHCommand.shellQuote(env[key]!))"
        }.joined(separator: " ")
        let command = assigns + " " + SSHRunner.commandLine(["perl", "-e", Self.perlSource])
        let outcome = await runner.run(command)
        switch outcome {
        case .unverifiable(let reason):
            throw RemoteHostError.unverifiable(host: hostName,
                                               doing: "reading files", reason: reason)
        case .answered(let code, let stdout, let stderr):
            if let parsed = Parsed(stdout: stdout) {
                if parsed.ok { return parsed }
                let message = parsed.message.isEmpty
                    ? FileServiceError(parsed.code, parsed.code).message
                    : parsed.message
                throw FileServiceError(parsed.code, message)
            }
            let detail = SSHRunner.firstLine(stderr)
                ?? (code == 0 ? "the file transport returned no protocol header" : "exit \(code)")
            throw FileServiceError(
                "remote_unsupported",
                "file transport on \(hostName) failed: \(detail)")
        }
    }

    struct Parsed {
        var ok: Bool
        var code: String
        var message: String
        var records: [Record]
        var stat: FileStatInfo?
        var body: Data?
        var truncated: Bool
        var total: Int?

        enum Record {
            case entry(kind: String, name: String)
            case list(String)
            case hit(path: String, line: Int, excerpt: String)
        }

        init?(stdout: String) {
            let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
            guard let first = lines.first, first == "ORCHARD-FILE/1", lines.count >= 3 else {
                return nil
            }
            let status = lines[1]
            let code = lines[2]
            ok = status == "ok"
            self.code = ok ? "ok" : (code.isEmpty ? "unreadable" : code)
            message = ""
            records = []
            truncated = false
            total = nil
            if !ok {
                message = lines.count > 3 ? String(lines[3]) : self.code
                if message.isEmpty { message = self.code }
                return
            }
            for line in lines.dropFirst(3) {
                if line.isEmpty { continue }
                let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
                    .map(String.init)
                guard let tag = cols.first else { continue }
                switch tag {
                case "ENTRY":
                    guard cols.count >= 3, let name = Self.decode(cols[2]) else { continue }
                    records.append(.entry(kind: cols[1], name: name))
                case "STAT":
                    guard cols.count >= 5,
                          let size = Int64(cols[1]),
                          let isDir = Int(cols[2]),
                          let isLink = Int(cols[3]),
                          let mtime = Double(cols[4]) else { continue }
                    stat = FileStatInfo(size: size, isDirectory: isDir != 0,
                                        isSymlink: isLink != 0, mtime: mtime)
                case "BODY":
                    guard cols.count >= 3, let data = Data(base64Encoded: cols[2]) else { continue }
                    body = data
                case "LIST":
                    guard cols.count >= 2, let path = Self.decode(cols[1]) else { continue }
                    records.append(.list(path))
                case "HIT":
                    guard cols.count >= 4,
                          let path = Self.decode(cols[1]),
                          let line = Int(cols[2]) else { continue }
                    let excerptBytes = Data(base64Encoded: cols[3]) ?? Data()
                    // Display-only: search never writes. Same lossy fallback FileService
                    // uses so a Latin-1 line still shows its ASCII matches.
                    let excerpt = FileService.text(of: excerptBytes)
                        ?? String(decoding: excerptBytes, as: UTF8.self)
                    records.append(.hit(path: path, line: line, excerpt: excerpt))
                case "TRUNCATED":
                    truncated = true
                case "TOTAL":
                    if cols.count >= 2 { total = Int(cols[1]) }
                default:
                    continue
                }
            }
        }

        private static func decode(_ b64: String) -> String? {
            guard let data = Data(base64Encoded: b64) else { return nil }
            return FileService.text(of: data) ?? String(decoding: data, as: UTF8.self)
        }
    }

    /// Far-side helper. Speaks only ASCII on stdout. Paths and bodies are base64.
    /// `perl` is the one scripting language still shipped with macOS and typical
    /// Linux hosts; a host without it fails typed rather than approximating.
    static let perlSource: String = #"""
use strict;
use warnings;
use Cwd qw(realpath);
use File::Basename qw(basename);
use File::Find;
use MIME::Base64 qw(encode_base64);
use Fcntl qw(O_RDONLY);

sub b64 { encode_base64($_[0], '') }
sub fail {
  my ($code, $msg) = @_;
  $msg = '' unless defined $msg;
  $msg =~ s/\s+/ /g;
  print "ORCHARD-FILE/1\nerr\n$code\n$msg\n";
  exit 0;
}
sub ok { print "ORCHARD-FILE/1\nok\nnone\n"; }
sub is_safe_rel {
  my ($rel) = @_;
  return 1 if !defined $rel || $rel eq '';
  return 0 if $rel =~ /\0/ || $rel =~ m{^/} || $rel =~ m{^~};
  for my $p (split m{/}, $rel, -1) {
    return 0 if $p eq '' || $p eq '.' || $p eq '..';
  }
  return 1;
}
sub assert_inside {
  my ($path, $root, $orig) = @_;
  return if $path eq $root;
  my $prefix = $root =~ m{/$} ? $root : "$root/";
  fail('path_escape', "path '$orig' resolves outside the worktree root")
    unless index($path, $prefix) == 0;
}
sub resolve {
  my ($root, $rel) = @_;
  fail('invalid_argument', 'empty worktree root') if $root eq '';
  fail('invalid_argument', 'root must be absolute') unless $root =~ m{^/};
  $root =~ s{/+$}{};
  fail('path_escape', "path '$rel' is not a safe worktree-relative path")
    unless is_safe_rel($rel);
  fail('not_found', '.') unless -e $root || -l $root;
  my $phys = realpath($root);
  fail('not_found', '.') unless defined $phys;
  $phys =~ s{/+$}{};
  return $phys if $rel eq '';
  my $joined = "$root/$rel";
  if (-e $joined || -l $joined) {
    my $real = realpath($joined);
    fail('not_found', $rel) unless defined $real;
    assert_inside($real, $phys, $rel);
    return $real;
  }
  my $candidate = "$phys/$rel";
  assert_inside($candidate, $phys, $rel);
  return $candidate;
}
sub emit_stat {
  my ($path) = @_;
  my @st = stat($path);
  fail('not_found', $path) unless @st;
  # `resolve` already followed symlinks, so this is the target — matching
  # FileService.stat, which stats the real path.
  my $is_link = (-l $path) ? 1 : 0;
  my $is_dir = (-d $path) ? 1 : 0;
  print "STAT\t$st[7]\t$is_dir\t$is_link\t$st[9]\n";
  return ($st[7], $is_dir, $is_link);
}
sub compile_res {
  my ($raw) = @_;
  return () unless defined $raw && $raw ne '';
  my @out;
  for my $p (split /\n/, $raw) {
    next if $p eq '';
    my $re = eval { qr/$p/ };
    fail('invalid_argument', 'invalid glob') unless $re;
    push @out, $re;
  }
  return @out;
}
sub any_re {
  my ($path, @res) = @_;
  return 0 unless @res;
  for my $re (@res) { return 1 if $path =~ $re; }
  return 0;
}
sub skip_kind {
  my ($rel) = @_;
  return 0 unless $rel =~ /\.([^.]+)$/;
  my $ext = lc $1;
  return 1 if $ext =~ /^(png|jpg|jpeg|gif|webp|bmp|ico|svg|avif|heic|pdf|zip|mp3|mp4|mov|woff|woff2)$/;
  return 0;
}
sub excerpt {
  my ($line, $query, $case, $max) = @_;
  return $line if length($line) <= $max;
  my $hay = $case ? $line : lc $line;
  my $needle = $case ? $query : lc $query;
  my $idx = index($hay, $needle);
  if ($idx < 0) { return substr($line, 0, $max) . "..."; }
  my $mlen = length($needle);
  my $remain = $max - $mlen;
  $remain = 0 if $remain < 0;
  my $left = int($remain / 2);
  my $start = $idx - $left;
  $start = 0 if $start < 0;
  my $end = $start + $max;
  $end = length($line) if $end > length($line);
  $start = $end - $max;
  $start = 0 if $start < 0;
  my $snip = substr($line, $start, $end - $start);
  $snip = "..." . $snip if $start > 0;
  $snip .= "..." if $end < length($line);
  return $snip;
}

my $op = $ENV{ORCHARD_FILE_OP} // '';
my $root = $ENV{ORCHARD_FILE_ROOT} // '';
my $rel = $ENV{ORCHARD_FILE_REL} // '';
my $dots = ($ENV{ORCHARD_FILE_DOTS} // '0') eq '1' ? 1 : 0;
my $max = int($ENV{ORCHARD_FILE_MAX} // 0);
my $query = $ENV{ORCHARD_FILE_QUERY} // '';
my $limit = int($ENV{ORCHARD_FILE_LIMIT} // 0);
$limit = 1 if $limit < 1 && $op ne 'read' && $op ne 'stat' && $op ne 'read-dir';

if ($op eq 'read-dir') {
  my $dir = resolve($root, $rel);
  fail('not_found', $rel eq '' ? '.' : $rel) unless -e $dir || -l $dir;
  fail('not_a_directory', 'path is not a directory') unless -d $dir;
  opendir(my $dh, $dir) or fail('unreadable', $rel eq '' ? '.' : $rel);
  my @names = readdir($dh);
  closedir($dh);
  ok();
  for my $name (sort @names) {
    next if $name eq '.' || $name eq '..';
    next if !$dots && $name =~ /^\./;
    my $full = "$dir/$name";
    my $is_link = (-l $full) ? 1 : 0;
    my $kind = $is_link ? 'l' : ((-d $full) ? 'd' : 'f');
    print "ENTRY\t$kind\t" . b64($name) . "\n";
  }
  exit 0;
}

if ($op eq 'stat') {
  my $path = resolve($root, $rel);
  fail('not_found', $rel eq '' ? '.' : $rel) unless -e $path || -l $path;
  ok();
  emit_stat($path);
  exit 0;
}

if ($op eq 'read') {
  my $path = resolve($root, $rel);
  fail('not_found', $rel) unless -e $path || -l $path;
  fail('not_a_file', 'path is not a file') if -d $path;
  my @st = stat($path);
  fail('unreadable', $rel) unless @st;
  my $size = $st[7];
  fail('file_too_large', 'file exceeds preview budget') if $max > 0 && $size > $max;
  my $fh;
  sysopen($fh, $path, O_RDONLY) or fail('unreadable', $rel);
  binmode($fh);
  my $buf = '';
  my $got = sysread($fh, $buf, $size + 1);
  close($fh);
  fail('unreadable', $rel) unless defined $got;
  fail('file_too_large', 'file exceeds preview budget') if $max > 0 && length($buf) > $max;
  ok();
  my $is_link = (-l $path) ? 1 : 0;
  print "STAT\t" . length($buf) . "\t0\t$is_link\t$st[9]\n";
  print "BODY\t" . length($buf) . "\t" . b64($buf) . "\n";
  exit 0;
}

if ($op eq 'list' || $op eq 'search') {
  my $phys = resolve($root, '');
  my @include = compile_res($ENV{ORCHARD_FILE_INCLUDE_RE});
  my @exclude = compile_res($ENV{ORCHARD_FILE_EXCLUDE_RE});
  my $case = ($ENV{ORCHARD_FILE_CASE} // '0') eq '1' ? 1 : 0;
  my $perfile = int($ENV{ORCHARD_FILE_PERFILE} // 20);
  $perfile = 1 if $perfile < 1;
  my $file_budget = int($ENV{ORCHARD_FILE_FILEBUDGET} // 524288);
  my $total_budget = int($ENV{ORCHARD_FILE_TOTALBUDGET} // 8388608);
  my $excerpt_cap = int($ENV{ORCHARD_FILE_EXCERPT} // 200);
  $excerpt_cap = 16 if $excerpt_cap < 16;
  my $q = $query;
  my $q_cmp = $case ? $q : lc $q;
  if ($op eq 'search') {
    fail('invalid_argument', 'search requires a query') if $q eq '';
    fail('invalid_argument', 'query exceeds 8 KB') if length($q) > 8192;
  }
  my $prefix = $phys =~ m{/$} ? $phys : "$phys/";
  my @files;
  my $total = 0;
  my $truncated = 0;
  my $scanned = 0;
  my @hits;
  find({ no_chdir => 1, follow => 0, wanted => sub {
    return if $truncated && $op eq 'search';
    my $full = $File::Find::name;
    my $base = basename($full);
    if ($base eq '.git' && -d $full && !-l $full) {
      $File::Find::prune = 1;
      return;
    }
    return if $full eq $phys;
    return unless index($full, $prefix) == 0;
    my $relp = substr($full, length($prefix));
    return if $relp eq '';
    my $is_link = (-l $full) ? 1 : 0;
    my $is_dir = $is_link ? 0 : ((-d $full) ? 1 : 0);
    if (!$dots && $base =~ /^\./) {
      $File::Find::prune = 1 if $is_dir;
      return;
    }
    return if $is_dir;
    if ($op eq 'list') {
      if ($q ne '') {
        my $hay_n = lc $base;
        my $hay_p = lc $relp;
        my $qq = lc $q;
        return unless index($hay_n, $qq) >= 0 || index($hay_p, $qq) >= 0;
      }
      $total++;
      push @files, $relp if @files < $limit;
      return;
    }
    return if skip_kind($relp);
    return if @include && !any_re($relp, @include);
    return if any_re($relp, @exclude);
    my @st = stat($full);
    return unless @st;
    my $size = $st[7];
    return if $size <= 0 || $size > $file_budget;
    if ($scanned + $size > $total_budget) { $truncated = 1; return; }
    my $fh;
    sysopen($fh, $full, O_RDONLY) or return;
    binmode($fh);
    my $buf = '';
    my $got = sysread($fh, $buf, $size);
    close($fh);
    return unless defined $got;
    return if length($buf) > $file_budget;
    return if index(substr($buf, 0, 8192), "\0") >= 0;
    $scanned += length($buf);
    my $n = 0;
    my $file_hits = 0;
    for my $line (split /\n/, $buf, -1) {
      $line =~ s/\r$//;
      $n++;
      my $hay = $case ? $line : lc $line;
      next unless index($hay, $q_cmp) >= 0;
      if (@hits >= $limit || $file_hits >= $perfile) {
        $truncated = 1;
        last;
      }
      push @hits, [$relp, $n, excerpt($line, $q, $case, $excerpt_cap)];
      $file_hits++;
      $truncated = 1 if @hits >= $limit;
    }
  }}, $phys);
  ok();
  if ($op eq 'list') {
    print "TOTAL\t$total\n";
    print "TRUNCATED\t1\n" if $total > @files;
    for my $p (@files) { print "LIST\t" . b64($p) . "\n"; }
  } else {
    print "TRUNCATED\t1\n" if $truncated;
    print "TOTAL\t" . scalar(@hits) . "\n";
    for my $h (@hits) {
      print "HIT\t" . b64($h->[0]) . "\t$h->[1]\t" . b64($h->[2]) . "\n";
    }
  }
  exit 0;
}

fail('invalid_argument', "unknown file op '$op'");
"""#
}

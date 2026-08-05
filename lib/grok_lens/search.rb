# frozen_string_literal: true

module GrokLens
  class Search
    Result = Data.define(:session_id, :cwd, :title, :snippet, :rank)

    def initialize(grok_home: Config.grok_home)
      @grok_home = File.expand_path(grok_home)
    end

    def available?
      File.file?(db_path)
    end

    def db_path
      File.join(@grok_home, "sessions", "session_search.sqlite")
    end

    def query(q, limit: 40)
      q = q.to_s.strip
      return [] if q.empty? || !available?

      require "sqlite3"
      db = SQLite3::Database.new(db_path, readonly: true)
      db.results_as_hash = true
      # FTS5: quote multi-word as phrase-ish OR AND terms
      fts = fts_query(q)
      sql = <<~SQL
        SELECT d.session_id, d.cwd, d.title,
               snippet(session_docs_fts, 1, '«', '»', '…', 12) AS snip,
               bm25(session_docs_fts) AS rank
        FROM session_docs_fts
        JOIN session_docs d ON d.rowid = session_docs_fts.rowid
        WHERE session_docs_fts MATCH ?
        ORDER BY rank
        LIMIT ?
      SQL
      rows = db.execute(sql, [fts, limit])
      rows.map do |r|
        Result.new(
          session_id: r["session_id"],
          cwd: r["cwd"],
          title: r["title"].to_s,
          snippet: r["snip"].to_s,
          rank: r["rank"]
        )
      end
    rescue StandardError
      # Fallback: LIKE on title/content if FTS MATCH fails
      like_fallback(q, limit)
    ensure
      db&.close
    end

    private

    def fts_query(q)
      terms = q.scan(/[\w\-.\/:]+/).first(8)
      return q.gsub(/"/, '""') if terms.empty?

      terms.map { |t| t.include?(" ") ? "\"#{t}\"" : t }.join(" ")
    end

    def like_fallback(q, limit)
      require "sqlite3"
      db = SQLite3::Database.new(db_path, readonly: true)
      db.results_as_hash = true
      pat = "%#{q}%"
      rows = db.execute(
        "SELECT session_id, cwd, title, substr(content, 1, 160) AS snip, 0 AS rank
         FROM session_docs
         WHERE title LIKE ? OR content LIKE ?
         ORDER BY updated_at DESC LIMIT ?",
        [pat, pat, limit]
      )
      rows.map do |r|
        Result.new(
          session_id: r["session_id"],
          cwd: r["cwd"],
          title: r["title"].to_s,
          snippet: r["snip"].to_s,
          rank: 0
        )
      end
    rescue StandardError
      []
    ensure
      db&.close
    end
  end
end

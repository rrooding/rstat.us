# An Update is a particular status message sent by one of our users.

class Update
  require 'cgi'
  include MongoMapper::Document
  include MongoMapperExt::Filter

  # Determines what constitutes a username inside an update text
  USERNAME_REGULAR_EXPRESSION = /(^|[ \t\n\r\f"'\(\[{]+)@([^ \t\n\r\f&?=@%\/\#]*[^ \t\n\r\f&?=@%\/\#.!:;,"'\]}\)])(?:@([^ \t\n\r\f&?=@%\/\#]*[^ \t\n\r\f&?=@%\/\#.!:;,"'\]}\)]))?/

  # Updates are aggregated in Feeds
  belongs_to :feed

  # Updates are written by Authors
  belongs_to :author
  validates_presence_of :author_id

  # The content of the update, unaltered, is stored here
  key :text, String, :default => ""
  validates_length_of :text, :minimum => 1, :maximum => 140

  # Mentions are stored in the following array
  key :mention_ids, Array
  many :mentions, :in => :mention_ids, :class_name => 'Author'
  before_save :get_mentions

  # The following are extra features and identifications for the update
  key :tags, Array, :default => []
  key :language, String
  key :twitter, Boolean
  key :facebook, Boolean

  # For speed, we generate the html for the update upon saving
  key :html, String
  before_save :generate_html

  # We also generate the tags upon editing the update
  before_save :get_tags

  # We determine and store the language used within this update
  before_create :get_language

  # Updates have a remote url that globally identifies them
  key :remote_url, String

  # Reply and restate identifiers
  # Local Update id: (nil if remote)
  key :referral_id
  # Remote Update url: (nil if local)
  key :referral_url, String

  filterable_keys :text

  def referral
    Update.first(:id => referral_id)
  end

  def url
    feed.local? ? "/updates/#{id}" : remote_url
  end

  def url=(the_url)
    self.remote_url = the_url
  end

  def to_html
    self.html || generate_html
  end

  def mentioned?(username)
    matches = text.match(/@#{username}\b/)
    matches.nil? ? false : matches.length > 0
  end

  after_create :send_to_external_accounts

  timestamps!

  def self.hashtag_search(tag, opts)
    popts = {
      :page => opts[:page],
      :per_page => opts[:per_page]
    }
    where(:tags.in => [tag]).order(['created_at', 'descending']).paginate(popts)
  end

  def self.hot_updates
    all(:limit => 6, :order => 'created_at desc')
  end

  def get_tags
    self[:tags] = self.text.scan(/#([\w\-\.]*)/).flatten
  end

  def get_language
    self[:language] = self.text.language
  end

  # Return OStatus::Entry instance describing this Update
  def to_atom(base_uri)
    links = []
    links << Atom::Link.new({ :href => ("#{base_uri}updates/#{self.id.to_s}")})
    mentions.each do |author|
      author_url = author.url
      if author_url.start_with?("/")
        author_url = base_uri + author_url[1..-1]
      end
      links << Atom::Link.new({ :rel => 'ostatus:attention', :href => author_url })
      links << Atom::Link.new({ :rel => 'mentioned', :href => author_url })
    end

    OStatus::Entry.new(:title => self.text,
                       :content => Atom::Content::Html.new(self.html),
                       :updated => self.updated_at,
                       :published => self.created_at,
                       :activity => OStatus::Activity.new(:object_type => :note),
                       :author => self.author.to_atom(base_uri),
                       :id => "#{base_uri}updates/#{self.id.to_s}",
                       :links => links)
  end

  protected

  def get_mentions
    self.mentions = []

    out = CGI.escapeHTML(text)

    out.gsub!(USERNAME_REGULAR_EXPRESSION) do |match|
      if $3 and a = Author.first(:username => /^#{$2}$/i, :domain => /^#{$3}$/i)
        self.mentions << a
      elsif not $3 and authors = Author.all(:username => /^#{$2}$/i)
        a = nil

        if authors.count == 1
          a = authors.first
        else
          # Disambiguate

          # Is it in update to this author?
          if in_reply_to = referral
            if authors.contains in_reply_to.author
              a = in_reply_to.author
            end
          end

          # Is this update is generated by a local user,
          # look at who they are following
          if a.nil? and user = self.author.user
            authors.each do |author|
              if user.followings.contains author
                a = author
              end
            end
          end
        end

        self.mentions << a unless a.nil?
      end
      match
    end

    self.mentions
  end

  # Generate and store the html
  def generate_html
    out = CGI.escapeHTML(text)

    # Replace any absolute addresses with a link
    # Note: Do this first! Otherwise it will add anchors inside anchors!
    out.gsub!(/(http[s]?:\/\/\S+[a-zA-Z0-9\/}])/, "<a href='\\1'>\\1</a>")

    # we let almost anything be in a username, except those that mess with urls.
    # but you can't end in a .:;, or !
    # also ignore container chars [] () "" '' {}
    # XXX: the _correct_ solution will be to use an email validator
    out.gsub!(USERNAME_REGULAR_EXPRESSION) do |match|
      if $3 and a = Author.first(:username => /^#{$2}$/i, :domain => /^#{$3}$/i)
        author_url = a.url
        if author_url.start_with?("/")
          author_url = "http://#{author.domain}#{author_url}"
        end
        "#{$1}<a href='#{author_url}'>@#{$2}@#{$3}</a>"
      elsif not $3 and a = Author.first(:username => /^#{$2}$/i)
        author_url = a.url
        if author_url.start_with?("/")
          author_url = "http://#{author.domain}#{author_url}"
        end
        "#{$1}<a href='#{author_url}'>@#{$2}</a>"
      else
        match
      end
    end
    out.gsub!(/(^|\s+)#(\w+)/) do |match|
      "#{$1}<a href='/hashtags/#{$2}'>##{$2}</a>"
    end
    self.html = out
  end

  # If a user has twitter or facebook enabled on their account and they checked
  # either twitter, facebook or both on update form, repost the update to
  # facebook or twitter.
  def send_to_external_accounts
    return if ENV['RACK_ENV'] == 'development'

    # If there is no user we can't get to the oauth tokens, abort!
    if author.user
      # If the twitter flag is true and the user has a twitter account linked
      # send the update
      if self.twitter? && author.user.twitter?
        begin
          Twitter.configure do |config|
            config.consumer_key = ENV["CONSUMER_KEY"]
            config.consumer_secret = ENV["CONSUMER_SECRET"]
            config.oauth_token = author.user.twitter.oauth_token
            config.oauth_token_secret = author.user.twitter.oauth_secret
          end

          Twitter.update(text)
        rescue Exception => e
          #I should be shot for doing this.
        end
      end

      # If the facebook flag is true and the user has a facebook account linked
      # send the update
      if self.facebook? && author.user.facebook?
        begin
          user = FbGraph::User.me(author.user.facebook.oauth_token)
          user.feed!(:message => text)
        rescue Exception => e
          #I should be shot for doing this.
        end
      end
    end

  end

end

# == Schema Information
#
# Table name: datasets
#
#  id              :integer          not null, primary key
#  name            :string
#  url             :string
#  user_id         :integer
#  created_at      :datetime
#  updated_at      :datetime
#  repo            :string
#  description     :text
#  publisher_name  :string
#  publisher_url   :string
#  license         :string
#  frequency       :string
#  datapackage_sha :text
#  owner           :string
#  owner_avatar    :string
#  build_status    :string
#  full_name       :string
#  certificate_url :string
#  job_id          :string
#  restricted      :boolean          default(FALSE)
#

require 'git_data'

class Dataset < ApplicationRecord

  belongs_to :user
  has_many :dataset_files

  after_create :create_repo_and_populate
  after_update :update_dataset_in_github, :make_repo_public_if_appropriate, :publish_public_views
  after_destroy :delete_dataset_in_github

  validate :check_repo, on: :create
  validates_associated :dataset_files

  def report_status(channel_id)
    Rails.logger.info "Dataset: in report_status #{channel_id}"
    Rails.logger.info "Dataset: file count: #{dataset_files.count}"
    if valid?
      Pusher[channel_id].trigger('dataset_created', self) if channel_id
      Rails.logger.info "Dataset: Valid so now do the save and trigger the after creates"
      save
    else
      Rails.logger.info "Dataset: In valid, so push to pusher"
      messages = errors.full_messages
      dataset_files.each do |file|
        unless file.valid?
          Rails.logger.info "Dataset: Check file is valid"
          (file.errors.messages[:file] || []).each do |message|
            messages << "Your file '#{file.title}' #{message}"
          end
        end
      end
      if channel_id
        Pusher[channel_id].trigger('dataset_failed', messages.uniq)
      else
        Error.create(job_id: self.job_id, messages: messages.uniq)
      end
    end
  end

  def delete_file_from_repo(filename)
    @repo.delete_file(filename)
  end

  def path(filename, folder = "")
    File.join([folder,filename].reject { |n| n.blank? })
  end

  def config
    {
      "data_dir" => '.',
      "update_frequency" => frequency,
      "permalink" => 'pretty'
    }.to_yaml
  end

  def github_url
    "http://github.com/#{full_name}"
  end

  def gh_pages_url
    "http://#{repo_owner}.github.io/#{repo}"
  end

  def full_name
    "#{repo_owner}/#{repo}"
  end

  def repo_owner
    owner.presence || user.github_username
  end

  def fetch_repo(client = user.octokit_client)
    begin
      Rails.logger.info "in fetch_repo"
      @repo = GitData.find(repo_owner, self.name, client: client)
      # This is in for backwards compatibility at the moment required for API

    rescue Octokit::NotFound
      Rails.logger.info "in fetch_repo - not found"
      @repo = nil
    end
  end

  def complete_publishing
    fetch_repo
    set_owner_avatar 
    publish_public_views(true)
    send_success_email
    send_tweet_notification
  end

  private

    # This is a callback
    def create_repo_and_populate
      Rails.logger.info "in NEW create_repo_and_populate"
      CreateRepository.perform_async(id)
    end

    # This is a callback
    def update_dataset_in_github
      Rails.logger.info "in update_dataset_in_github"
      jekyll_service.update_dataset_in_github
    end

    # This is a callback
    def make_repo_public_if_appropriate
      Rails.logger.info "in make_repo_public_if_appropriate"
      # Should the repo be made public?
      if restricted_changed? && restricted == false
        @repo.make_public
      end
    end

    # This is a callback
    def delete_dataset_in_github
      jekyll_service.delete_dataset_in_github
    end

    def check_repo
      Rails.logger.info "in check_repo"
      repo_name = "#{repo_owner}/#{name.parameterize}"
      if user.octokit_client.repository?(repo_name)
        errors.add :repository_name, 'already exists'
      end
    end

    def set_owner_avatar
      Rails.logger.info "in set_owner_avatar"
      if owner.blank?
        update_column :owner_avatar, user.avatar
      else 
        update_column :owner_avatar, Rails.configuration.octopub_admin.organization(owner).avatar_url
      end
    end

    def send_success_email
      Rails.logger.info "in send_success_email"
      DatasetMailer.success(self).deliver
    end

    def send_tweet_notification
      Rails.logger.info "in send_tweet_notification"
      if ENV["TWITTER_CONSUMER_KEY"] && user.twitter_handle
        twitter_client = Twitter::REST::Client.new do |config|
          config.consumer_key        = ENV["TWITTER_CONSUMER_KEY"]
          config.consumer_secret     = ENV["TWITTER_CONSUMER_SECRET"]
          config.access_token        = ENV["TWITTER_TOKEN"]
          config.access_token_secret = ENV["TWITTER_SECRET"]
        end
        twitter_client.update("@#{user.twitter_handle} your dataset \"#{self.name}\" is now published at #{self.gh_pages_url}")
      end
    end

    def jekyll_service
      Rails.logger.info "jekyll_service called, so set with #{repo}"
      @jekyll_service ||= JekyllService.new(self, @repo)
    end

    # This is a callback
    def publish_public_views(new_record = false)
      Rails.logger.info "in publish_public_views"
      return if restricted
      if new_record || restricted_changed?
        # This is either a new record or has just been made public

        create_public_views
      end
      # updates to existing public repos are handled in #update_in_github
    end

    def create_public_views
      Rails.logger.info "in create_public_views"
      jekyll_service.create_jekyll_files
      jekyll_service.push_to_github
      wait_for_gh_pages_build
      create_certificate
    end

    def wait_for_gh_pages_build(delay = 5)
      Rails.logger.info "in wait_for_gh_pages_build"
      sleep(delay) while !gh_pages_built?
    end

    def gh_pages_built?
      Rails.logger.info "in gh_pages_built"
      user.octokit_client.pages(full_name).status == "built"
    end

    def create_certificate
      Rails.logger.info "in create_certificate"
      cert = CertificateFactory::Certificate.new gh_pages_url

      gen = cert.generate

      if gen[:success] == 'pending'
        result = cert.result
        add_certificate_url(result[:certificate_url])
      end
    end

    def add_certificate_url(url)
      return if url.nil?

      url = url.gsub('.json', '')
      update_column(:certificate_url, url)

      config = {
        "data_source" => ".",
        "update_frequency" => frequency,
        "certificate_url" => "#{certificate_url}/badge.js"
      }.to_yaml

      fetch_repo(user.octokit_client)
      jekyll_service.update_file_in_repo('_config.yml', config)
      jekyll_service.push_to_github
    end
end

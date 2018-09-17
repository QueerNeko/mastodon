class AddPublicInLocalFieldInStatuses < ActiveRecord::Migration[5.2]
  def change
    add_column :statuses, :public_in_local, :boolean
  end
end

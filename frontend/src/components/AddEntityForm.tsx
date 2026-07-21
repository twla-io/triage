import { useState, type ReactNode } from 'react'
import { Button, Group, TextInput } from '@mantine/core'

interface AddEntityFormProps {
  label: string
  onSubmit: (name: string) => void
  pending?: boolean
  /** Extra fields beyond name+submit (e.g. Healthcare Service's duration select). */
  children?: ReactNode
}

// Generic add-form: a name field plus submit, reused as-is for Doctor/
// Patient, and extended via `children` for Healthcare Service's one extra
// (duration) field -- name+submit stays the shared shape, not duplicated
// per entity.
export function AddEntityForm({ label, onSubmit, pending, children }: AddEntityFormProps) {
  const [name, setName] = useState('')

  const handleSubmit = (event: React.FormEvent) => {
    event.preventDefault()
    if (!name.trim()) return
    onSubmit(name.trim())
    setName('')
  }

  return (
    <form onSubmit={handleSubmit}>
      <Group align="flex-end" wrap="wrap">
        <TextInput
          label={label}
          placeholder="Name"
          value={name}
          onChange={(event) => setName(event.currentTarget.value)}
          required
        />
        {children}
        <Button type="submit" loading={pending}>
          Add
        </Button>
      </Group>
    </form>
  )
}
